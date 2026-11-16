#!/usr/bin/env bash
# LeadFlow Ops demo: CRM -> n8n -> PostgreSQL sync with failure replay, tenant isolation,
# verified backup/restore and release rollback. Every scenario asserts its own outcome.
#
#   ./demo.sh setup                 generate .env, start the stack, apply migrations
#   ./demo.sh all [--pause]         run the five scenarios in order (--pause waits for Enter at each step)
#   ./demo.sh 1|2|3|4|5             run one scenario (see list below)
#   ./demo.sh status | sync | reset
#
#   1  crm-sync        initial + incremental sync, idempotent re-run, reconciliation
#   2  failure-replay  CRM outage for one tenant, alert, untouched watermark, replay, quarantine
#   3  tenant-denial   RLS isolation through the API: read, filter, update, insert, forged token
#   4  backup-restore  verified backup, restore drill, accidental delete, promoted restore, catch-up
#   5  rollback        faulty release breaks the sync, alert, one-step rollback, replay
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib.sh"

ORG_1=org_palmcrest
ORG_2=org_bluedune

for arg in "$@"; do [ "$arg" = "--pause" ] && export DEMO_PAUSE=1; done

# ── helpers ─────────────────────────────────────────────────────────────────────────────

pretty() { "$PY" -c 'import json,sys; print(json.dumps(json.load(sys.stdin), indent=2, ensure_ascii=False))'; }

crm_post() { curl -fsS -X POST "$CRM_URL$1" -H 'Content-Type: application/json' -d "$2"; }

last_run_id() { sql "select coalesce(max(id), 0) from sync.runs"; }

# Trigger the n8n workflow through its webhook and wait until every run it opened has finished.
trigger_sync() { # trigger: manual | replay
  local trigger="${1:-manual}" before
  before="$(last_run_id)"
  # After a restart, n8n answers /healthz before it has re-registered webhooks; retry until it accepts.
  local accepted=0
  for _ in $(seq 1 30); do
    if curl -fsS -X POST "$N8N_URL/webhook/crm-sync" -H 'Content-Type: application/json' \
         -d "{\"trigger\": \"$trigger\"}" >/dev/null 2>&1; then accepted=1; break; fi
    sleep 2
  done
  [ "$accepted" = "1" ] || die "n8n webhook did not accept the trigger within 60s"
  for _ in $(seq 1 75); do
    sleep 2
    if [ "$(sql "select count(*) from sync.runs where id > $before")" -gt 0 ] &&
       [ "$(sql "select count(*) from sync.runs where id > $before and status = 'running'")" = "0" ]; then
      sql_table "select run, tenant, trigger, replay_of, status, pages, fetched, inserted, updated, unchanged,
                        quarantined, error
                   from sync.run_report where run > $before order by run"
      return 0
    fi
  done
  die "sync runs did not finish within 150s"
}

run_status() { sql "select status from sync.runs where tenant_id = $1 order by id desc limit 1"; }

# Compare CRM and warehouse record-by-record (id + version). Quarantined records are accounted for.
reconcile() {
  local tenant_id="$1" org="$2" label crm wh quarantined expected
  label="$(sql "select name from core.tenants where id = $tenant_id")"
  crm="$(curl -fsS "$CRM_URL/admin/manifest?org=$org" | tr -d '\r' | LC_ALL=C sort)"
  wh="$(sql "select crm_id || '|' || extract(epoch from crm_modified_at)::bigint
               from core.leads where tenant_id = $tenant_id" | LC_ALL=C sort)"
  quarantined="$(sql "select distinct q.crm_id from sync.quarantine q
                       where q.tenant_id = $tenant_id and q.crm_id is not null
                         and not exists (select 1 from core.leads l
                                          where l.tenant_id = q.tenant_id and l.crm_id = q.crm_id)")"
  if [ -n "$quarantined" ]; then
    expected="$(grep -v -F -f <(printf '%s\n' "$quarantined" | sed 's/$/|/') <<<"$crm" || true)"
  else
    expected="$crm"
  fi
  local n_crm n_wh n_q
  n_crm="$(grep -c . <<<"$crm" || true)"; n_wh="$(grep -c . <<<"$wh" || true)"
  n_q="$(grep -c . <<<"$quarantined" || true)"
  if [ "$expected" = "$wh" ]; then
    ok "$label: CRM $n_crm = warehouse $n_wh + quarantined $n_q, every id and version matches"
  else
    printf '%s\n' "$(diff <(echo "$expected") <(echo "$wh") | head -10)"
    die "$label: CRM and warehouse differ"
  fi
}

reconcile_all() { reconcile 1 "$ORG_1"; reconcile 2 "$ORG_2"; }

watermark() { sql "select to_char(last_modified_at at time zone 'Asia/Dubai', 'YYYY-MM-DD HH24:MI:SS')
                     from sync.watermarks where tenant_id = $1"; }

health() { curl -fsS "$API_URL/rpc/health"; }
health_status() { health | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["status"])'; }

show_alerts_since() { # count already seen
  curl -fsS "$CRM_URL/hooks/alerts" | "$PY" -c '
import json, sys
seen = int(sys.argv[1])
for a in json.load(sys.stdin)[seen:]:
    print("   #ops-alerts", a["at"][11:19], "|", a["text"])' "$1"
}
alert_count() { curl -fsS "$CRM_URL/hooks/alerts" | "$PY" -c 'import json,sys; print(len(json.load(sys.stdin)))'; }

token_for() { JWT_SECRET="$JWT_SECRET" "$PY" tools/mint_jwt.py "$@"; }

# ── commands ────────────────────────────────────────────────────────────────────────────

cmd_setup() {
  require_tools
  banner "Setup"
  if [ ! -f .env ]; then
    rnd() { openssl rand -hex "$1"; }
    cat > .env <<EOF
POSTGRES_PASSWORD=$(rnd 16)
AUTHENTICATOR_PASSWORD=$(rnd 16)
SYNC_WORKER_PASSWORD=$(rnd 16)
JWT_SECRET=$(rnd 32)
CRM_API_TOKEN=$(rnd 16)
N8N_ENCRYPTION_KEY=$(rnd 24)
BACKUP_KEEP=14
EOF
    ok ".env created with random secrets (git-ignored)"
  fi
  load_env
  mkdir -p backups
  docker compose up -d --build db mock-crm
  wait_for "PostgreSQL ready" docker compose exec -T db pg_isready -U postgres -d "$DB_NAME"
  wait_for "mock CRM ready" curl -fsS "$CRM_URL/health"
  scripts/migrate.sh up
  docker compose up -d api n8n
  wait_for "API ready" curl -fsS "$API_URL/rpc/health"
  wait_for "n8n ready (workflow imported and published)" curl -fsS "$N8N_URL/healthz"
  ok "stack is up: n8n $N8N_URL  ·  API $API_URL  ·  mock CRM $CRM_URL"
}

cmd_status() {
  load_env
  banner "Status"
  scripts/migrate.sh status
  sql_table "select t.slug as tenant, count(l.crm_id) as leads,
                    to_char(w.last_modified_at at time zone 'Asia/Dubai', 'YYYY-MM-DD HH24:MI:SS') as watermark_gst
               from core.tenants t join sync.watermarks w on w.tenant_id = t.id
               left join core.leads l on l.tenant_id = t.id
              group by t.id, t.slug, w.last_modified_at order by t.id"
  sql_table "select * from sync.run_report order by run desc limit 8"
  sql_table "select * from sync.health_detail"
  info "public health endpoint (aggregates only):"
  health | pretty
}

scenario_1() {
  load_env
  banner "1 · CRM sync: initial load, incremental changes, idempotent re-run"

  step "Initial sync: n8n pulls every lead for both agencies from the CRM API"
  trigger_sync manual
  reconcile_all

  step "Agents work in the CRM: new enquiries arrive and existing leads move stage"
  crm_post /admin/simulate "{\"org\": \"$ORG_1\", \"new\": 8, \"updates\": 5}" | pretty
  crm_post /admin/simulate "{\"org\": \"$ORG_2\", \"new\": 4, \"updates\": 3}" | pretty

  step "Incremental sync: only records changed since each tenant's watermark are fetched"
  trigger_sync manual
  assert_eq "$(sql "select inserted || '/' || updated from sync.runs where tenant_id = 1 order by id desc limit 1")" \
    "8/5" "Palm Crest: 8 inserted, 5 updated"
  assert_eq "$(sql "select inserted || '/' || updated from sync.runs where tenant_id = 2 order by id desc limit 1")" \
    "4/3" "Blue Dune: 4 inserted, 3 updated"
  reconcile_all

  step "Bulk import: 450 leads land in the same second (e.g. a portal CSV import), more than one API page"
  crm_post /admin/simulate "{\"org\": \"$ORG_1\", \"new\": 450}" | pretty
  trigger_sync manual
  assert_eq "$(sql "select inserted from sync.runs where tenant_id = 1 order by id desc limit 1")" \
    "450" "all 450 stored in one run (n8n paged through the API until more_records = false)"
  reconcile_all

  step "Run it again with nothing new: the sync is idempotent"
  trigger_sync manual
  assert_eq "$(sql "select sum(inserted + updated) from sync.runs where id in
                    (select max(id) from sync.runs group by tenant_id)")" "0" "re-run wrote nothing new"
  assert_eq "$(sql "select count(*) - count(distinct (tenant_id, crm_id)) from core.leads")" "0" \
    "zero duplicates (natural key tenant_id + crm_id)"
}

scenario_2() {
  load_env
  banner "2 · Failure and replay: CRM outage for one tenant"
  local wm_before alerts_before failed_id

  step "Transient blip first: the CRM rate-limits one request (HTTP 429). n8n retries, no alert needed"
  alerts_before="$(alert_count)"
  crm_post /admin/chaos "{\"mode\": \"rate_limit\", \"count\": 1, \"org\": \"$ORG_1\"}" >/dev/null
  trigger_sync manual
  assert_eq "$(run_status 1)" "succeeded" "retry absorbed the 429, run succeeded"
  assert_eq "$(alert_count)" "$alerts_before" "no alert raised for a self-healing blip"

  step "New leads arrive, including one malformed record (no name, phone 'call me after 6')"
  crm_post /admin/simulate "{\"org\": \"$ORG_1\", \"new\": 10, \"updates\": 2, \"poison\": 1}" | pretty
  crm_post /admin/simulate "{\"org\": \"$ORG_2\", \"new\": 3}" >/dev/null
  wm_before="$(watermark 1)"
  alerts_before="$(alert_count)"
  info "Palm Crest watermark before: $wm_before"

  step "The CRM starts returning HTTP 500 for Palm Crest only (persistent, more than n8n's retries)"
  crm_post /admin/chaos "{\"mode\": \"http_500\", \"count\": 20, \"org\": \"$ORG_1\"}" | pretty

  step "Scheduled sync runs: Palm Crest fails after retries, Blue Dune is unaffected"
  trigger_sync manual
  assert_eq "$(run_status 1)" "failed" "Palm Crest run marked failed"
  assert_eq "$(run_status 2)" "succeeded" "Blue Dune run succeeded (failures are isolated per tenant)"
  assert_eq "$(watermark 1)" "$wm_before" "Palm Crest watermark NOT advanced (nothing skipped)"
  info "alert posted by n8n:"
  show_alerts_since "$alerts_before"
  assert_eq "$(health_status)" "degraded" "health endpoint reports degraded"
  failed_id="$(sql "select id from sync.runs where tenant_id = 1 order by id desc limit 1")"

  step "CRM recovers. Replay: the same window is fetched again, nothing is duplicated"
  crm_post /admin/chaos '{"mode": "off"}' >/dev/null
  trigger_sync replay
  assert_eq "$(run_status 1)" "succeeded" "replay succeeded"
  assert_eq "$(sql "select replay_of from sync.runs where tenant_id = 1 order by id desc limit 1")" \
    "$failed_id" "replay is linked to failed run #$failed_id (audit trail)"
  assert_eq "$(health_status)" "ok" "health back to ok"

  step "The malformed record was quarantined with a reason, not dropped silently, and did not block the batch"
  sql_table "select q.run_id, t.slug as tenant, q.crm_id, q.reason, q.payload ->> 'Mobile' as mobile
               from sync.quarantine q join core.tenants t on t.id = q.tenant_id order by q.id"
  reconcile_all
}

scenario_3() {
  load_env
  banner "3 · Tenant isolation: Palm Crest's user tries to reach Blue Dune's data"
  local t1 t2 forged other_lead body code

  t1="$(token_for 1)"; t2="$(token_for 2)"; forged="$(token_for 2 --forge)"
  other_lead="$(sql "select crm_id from core.leads where tenant_id = 2 order by crm_id limit 1")"

  step "Each agency's token sees only its own leads (same API, same table)"
  for pair in "1:$t1" "2:$t2"; do
    local tid="${pair%%:*}" tok="${pair#*:}" seen
    seen="$(curl -fsS "$API_URL/leads?select=tenant_id" -H "Authorization: Bearer $tok" |
            "$PY" -c 'import json,sys; r=json.load(sys.stdin); print(len(r), sorted({x["tenant_id"] for x in r}))')"
    info "tenant $tid token -> $seen"
    assert_eq "${seen#* }" "[$tid]" "tenant $tid sees only tenant $tid rows"
  done

  step "Palm Crest asks for Blue Dune's rows explicitly (?tenant_id=eq.2)"
  body="$(curl -fsS "$API_URL/leads?tenant_id=eq.2" -H "Authorization: Bearer $t1")"
  info "response: $body"
  assert_eq "$body" "[]" "filtered out by row-level security"

  step "Palm Crest tries to reassign Blue Dune lead $other_lead to its own agent"
  body="$(curl -sS -X PATCH "$API_URL/leads?crm_id=eq.$other_lead" -H "Authorization: Bearer $t1" \
          -H 'Content-Type: application/json' -H 'Prefer: return=representation' \
          -d '{"owner": "Palm Crest agent"}')"
  info "response: $body"
  assert_eq "$body" "[]" "0 rows updated"
  assert_eq "$(sql "select owner <> 'Palm Crest agent' from core.leads where tenant_id = 2 and crm_id = '$other_lead'")" \
    "t" "Blue Dune's row is unchanged in the database"

  step "Palm Crest tries to insert a lead into Blue Dune's book"
  body="$(curl -sS -w '\n%{http_code}' -X POST "$API_URL/leads" \
          -H "Authorization: Bearer $t1" -H 'Content-Type: application/json' \
          -d '{"tenant_id": 2, "crm_id": "INJECTED1", "full_name": "Injected", "stage": "New", "crm_modified_at": "2026-01-01T00:00:00Z"}')"
  code="$(tail -1 <<<"$body")"
  info "HTTP $code: $(sed '$d' <<<"$body")"
  assert_eq "$code" "403" "rejected: new row violates row-level security policy"

  step "No token, and a token signed with the wrong key"
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' "$API_URL/leads")" "401" "anonymous request rejected"
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' "$API_URL/leads" -H "Authorization: Bearer $forged")" \
    "401" "forged token rejected (signature check)"

  step "The n8n integration account itself cannot read leads, it can only call the sync functions"
  body="$(PGPASSWORD="$SYNC_WORKER_PASSWORD" docker compose exec -T -e PGPASSWORD db \
          psql -h 127.0.0.1 -U sync_worker -d "$DB_NAME" -X -q -c 'select count(*) from core.leads' 2>&1 | tr -d '\r' || true)"
  info "$body"
  case "$body" in *"permission denied"*) ok "sync_worker: permission denied on core.leads (least privilege)" ;;
                  *) die "sync_worker should not be able to read leads" ;; esac
}

scenario_4() {
  load_env
  banner "4 · Backup, restore drill, and a real restoration after an accident"
  local name before_count

  step "Take a backup: dump + sha256 + globals + manifest"
  name="$(scripts/backup.sh demo | tail -1)"
  ls -1 backups | grep -F "$name" | sed 's/^/   /'
  info "manifest:"; sed 's/^/     /' "backups/$name.manifest"

  step "Restore drill: restore into a scratch database and verify, live database untouched"
  scripts/restore.sh "$name"

  step "Business continues after the backup: new leads arrive and are synced"
  crm_post /admin/simulate "{\"org\": \"$ORG_1\", \"new\": 5, \"updates\": 2}" >/dev/null
  trigger_sync manual >/dev/null
  before_count="$(sql "select count(*) from core.leads where tenant_id = 1")"
  info "Palm Crest leads now: $before_count"

  step "ACCIDENT: an operator runs a cleanup script against the wrong tenant"
  sql "delete from core.leads where tenant_id = 1" >/dev/null
  info "Palm Crest leads after the accident: $(sql "select count(*) from core.leads where tenant_id = 1")"

  step "Restore the backup and promote it to live"
  scripts/restore.sh "$name" --promote
  assert_eq "$(manifest_of)" "$(tr -d '\r' < "backups/$name.manifest")" "live database equals the backup manifest"

  step "Catch-up: the restored watermark makes the next sync re-fetch everything changed after the backup"
  trigger_sync manual
  assert_eq "$(sql "select count(*) from core.leads where tenant_id = 1")" "$before_count" \
    "Palm Crest back to $before_count leads, including the ones created after the backup"
  reconcile_all
}

scenario_5() {
  load_env
  banner "5 · Faulty release and rollback"
  local alerts_before

  step "Current schema version"
  scripts/migrate.sh status

  step "Deploy release 004 (renames leads.phone). It applies cleanly, with an automatic pre-deploy backup"
  scripts/migrate.sh apply db/release-candidates/004_rename_phone_column.sql

  step "New leads arrive and the sync runs against the new schema"
  crm_post /admin/simulate "{\"org\": \"$ORG_1\", \"new\": 6}" >/dev/null
  crm_post /admin/simulate "{\"org\": \"$ORG_2\", \"new\": 2}" >/dev/null
  alerts_before="$(alert_count)"
  trigger_sync manual
  assert_eq "$(run_status 1)/$(run_status 2)" "failed/failed" "release 004 broke the sync for every tenant"
  show_alerts_since "$alerts_before"

  step "Roll back release 004 with its down migration (one command, one transaction)"
  scripts/migrate.sh down
  scripts/migrate.sh status

  step "Replay the failed window on the restored schema"
  trigger_sync replay
  assert_eq "$(run_status 1)/$(run_status 2)" "succeeded/succeeded" "sync healthy again"
  assert_eq "$(health_status)" "ok" "health ok"
  reconcile_all
}

cmd_reset() {
  docker compose down -v --remove-orphans
  rm -f backups/leadflow_*
  ok "stack and volumes removed (.env kept)"
}

case "${1:-}" in
  setup) cmd_setup ;;
  status) cmd_status ;;
  sync) load_env; trigger_sync manual ;;
  1|crm-sync) scenario_1 ;;
  2|failure-replay) scenario_2 ;;
  3|tenant-denial) scenario_3 ;;
  4|backup-restore) scenario_4 ;;
  5|rollback) scenario_5 ;;
  all)
    cmd_setup
    scenario_1; scenario_2; scenario_3; scenario_4; scenario_5
    banner "All five scenarios passed"
    ;;
  reset) cmd_reset ;;
  *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
