#!/usr/bin/env bash
# Shared helpers for the demo scripts. Sourced, not executed.
set -euo pipefail

# Git Bash on Windows rewrites arguments that look like /paths; container paths must pass through untouched.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Portable helpers: macOS ships python3 (no python) and shasum (no sha256sum);
# on Windows, python3 can be a Microsoft Store stub that does not run.
if python3 -c 'import sys' >/dev/null 2>&1; then PY=python3
elif python -c 'import sys' >/dev/null 2>&1; then PY=python
else PY=""; fi
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
require_tools() {
  local missing=() tool
  for tool in docker curl openssl; do command -v "$tool" >/dev/null 2>&1 || missing+=("$tool"); done
  [ -n "$PY" ] || missing+=("python3")
  docker compose version >/dev/null 2>&1 || missing+=("docker compose v2")
  [ "${#missing[@]}" -eq 0 ] || { printf 'missing required tools: %s\n' "${missing[*]}" >&2; exit 1; }
}

DB_NAME=leadflow
CRM_URL=http://127.0.0.1:8089
API_URL=http://127.0.0.1:3001
N8N_URL=http://127.0.0.1:5678

if [ -t 1 ] || [ "${DEMO_COLOR:-0}" = "1" ]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_GREEN=$'\e[32m'; C_RED=$'\e[31m'; C_YELLOW=$'\e[33m'; C_CYAN=$'\e[36m'
else
  C_RESET=; C_BOLD=; C_DIM=; C_GREEN=; C_RED=; C_YELLOW=; C_CYAN=
fi

banner() { printf '\n%s══════ %s ══════%s\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"; }
step()   { printf '\n%s▶ %s%s\n' "$C_BOLD" "$*" "$C_RESET"; pause_if_requested; }
info()   { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
ok()     { printf '  %s✔ %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn()   { printf '  %s! %s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
die()    { printf '  %s✖ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

pause_if_requested() {
  if [ "${DEMO_PAUSE:-0}" = "1" ] && [ -t 0 ]; then
    read -r -p "  ${C_DIM}[enter to continue]${C_RESET}" _ || true
  fi
}

load_env() {
  [ -f .env ] || die "missing .env, run ./demo.sh setup first"
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
}

# psql as the superuser inside the db container. Output is stripped of CRs for Windows terminals.
PSQL_ENV=(-e PGOPTIONS='-c client_min_messages=warning')
sql() {
  docker compose exec -T "${PSQL_ENV[@]}" db psql -U postgres -d "${2:-$DB_NAME}" -X -q -A -t -v ON_ERROR_STOP=1 \
    -c "$1" | tr -d '\r'
}
sql_table() {
  docker compose exec -T "${PSQL_ENV[@]}" db psql -U postgres -d "${2:-$DB_NAME}" -X -q -P pager=off \
    -v ON_ERROR_STOP=1 -c "$1" | tr -d '\r'
}

assert_eq() { # actual expected message
  if [ "$1" = "$2" ]; then ok "$3"; else die "$3 (expected '$2', got '$1')"; fi
}

# One line per fact we can verify after a restore. Same query for live and restored databases.
manifest_of() {
  sql "select 'schema_version=' || coalesce((select max(version) from public.schema_migrations), 'none')
       union all
       select 'leads.' || t.slug || '=' || count(l.crm_id) from core.tenants t
         left join core.leads l on l.tenant_id = t.id group by t.slug
       union all
       select 'leads.checksum=' || md5(coalesce(string_agg(tenant_id || ':' || crm_id || ':' ||
              extract(epoch from crm_modified_at)::bigint, ',' order by tenant_id, crm_id), ''))
         from core.leads
       union all
       select 'watermark.' || t.slug || '=' || extract(epoch from w.last_modified_at)::bigint
         from core.tenants t join sync.watermarks w on w.tenant_id = t.id
       union all
       select 'rls.core.leads=' || (relrowsecurity and relforcerowsecurity)
         from pg_class where oid = 'core.leads'::regclass
       order by 1" "${1:-$DB_NAME}"
}

wait_for() { # description, command...
  local what="$1"; shift
  for _ in $(seq 1 60); do
    if "$@" >/dev/null 2>&1; then ok "$what"; return 0; fi
    sleep 2
  done
  die "timed out waiting for $what"
}
