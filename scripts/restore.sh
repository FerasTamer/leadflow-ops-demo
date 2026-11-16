#!/usr/bin/env bash
# Verified restore. Never restores over the live database directly.
#
#   scripts/restore.sh <backup-name | latest>             drill: restore into a scratch DB and verify
#   scripts/restore.sh <backup-name | latest> --promote   ...then swap it in as the live database
#
# Steps: verify checksum -> restore into leadflow_restore_check -> compare against the manifest
# -> (promote) stop writers, swap databases by rename, keep the old one for forensics, restart, health check.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env

[ $# -ge 1 ] || die "usage: restore.sh <backup-name|latest> [--promote]"
name="$1"; promote="${2:-}"
if [ "$name" = "latest" ]; then
  name="$(ls -1t backups/leadflow_*.dump 2>/dev/null | head -1 || true)"
  [ -n "$name" ] || die "no backups found"
  name="$(basename "${name%.dump}")"
fi
case "$name" in *[!A-Za-z0-9._-]*) die "invalid backup name" ;; esac
[ -f "backups/$name.dump" ] || die "backup not found: backups/$name.dump"
[ -f "backups/$name.manifest" ] || die "manifest missing for $name"
scratch="${DB_NAME}_restore_check"

info "1/4 verifying checksum"
docker compose exec -T db sh -c "cd /backups && sha256sum -c $name.dump.sha256" >/dev/null \
  || die "checksum mismatch: backup file is corrupt, refusing to restore"
ok "checksum verified"

info "2/4 restoring into scratch database $scratch"
sql "drop database if exists $scratch with (force)" postgres >/dev/null
sql "create database $scratch" postgres >/dev/null
docker compose exec -T db pg_restore -U postgres -d "$scratch" --exit-on-error "/backups/$name.dump"
ok "restored into $scratch"

info "3/4 comparing restored data with the backup manifest"
if ! diff <(cat "backups/$name.manifest" | tr -d '\r') <(manifest_of "$scratch") >/dev/null; then
  diff <(cat "backups/$name.manifest" | tr -d '\r') <(manifest_of "$scratch") || true
  die "restored database does not match the manifest"
fi
ok "restored data matches manifest exactly ($(grep -c . "backups/$name.manifest") checks: row counts, checksum, watermarks, RLS)"

if [ "$promote" != "--promote" ]; then
  sql "drop database $scratch with (force)" postgres >/dev/null
  ok "drill passed, scratch database dropped (live database untouched)"
  exit 0
fi

info "4/4 promoting: stopping writers, swapping databases"
parked="${DB_NAME}_pre_restore_$(date -u +%Y%m%d%H%M%S)"
# Whatever happens below, never leave the API and n8n stopped.
trap 'docker compose start api n8n >/dev/null 2>&1 || true' EXIT
docker compose stop n8n api >/dev/null 2>&1
sql "select pg_terminate_backend(pid) from pg_stat_activity
      where datname in ('$DB_NAME', '$scratch') and pid <> pg_backend_pid()" postgres >/dev/null
sql "alter database $DB_NAME rename to $parked" postgres >/dev/null
sql "alter database $scratch rename to $DB_NAME" postgres >/dev/null
docker compose start api n8n >/dev/null 2>&1
wait_for "API healthy after restore" curl -fsS "$API_URL/rpc/health"
wait_for "n8n healthy after restore" curl -fsS "$N8N_URL/healthz"
ok "restore promoted. Previous database parked as $parked (drop it after sign-off)"
