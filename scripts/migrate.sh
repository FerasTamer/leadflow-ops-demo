#!/usr/bin/env bash
# Versioned migrations with a recorded checksum, automatic pre-deploy backup, and one-step rollback.
#
#   scripts/migrate.sh up              apply every pending file in db/migrations
#   scripts/migrate.sh apply <file>    apply one release file (e.g. db/release-candidates/004_*.sql)
#   scripts/migrate.sh down            roll back the latest applied version using its .down.sql
#   scripts/migrate.sh status
#
# Each migration runs in a single transaction together with its bookkeeping row,
# so a failed migration leaves no trace, and PostgREST is told to reload its schema cache.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env

ensure_table() {
  sql "create table if not exists public.schema_migrations (
         version    text primary key,
         file       text not null,
         checksum   text not null,
         applied_at timestamptz not null default now())" >/dev/null
}

version_of() { basename "$1" | cut -d_ -f1; }
checksum_of() { sha256_file "$1"; }
is_applied() { [ -n "$(sql "select 1 from public.schema_migrations where version = '$1'")" ]; }

run_in_tx() { # stdin = SQL
  # Role passwords are injected as psql variables on stdin, never on the command line,
  # so they do not show up in the host's process list.
  local pw
  for pw in "$AUTHENTICATOR_PASSWORD" "$SYNC_WORKER_PASSWORD"; do
    case "$pw" in *[!A-Za-z0-9]*|'') die "role passwords must be alphanumeric (see .env)" ;; esac
  done
  {
    printf "\\\\set authenticator_password '%s'\n" "$AUTHENTICATOR_PASSWORD"
    printf "\\\\set sync_worker_password '%s'\n" "$SYNC_WORKER_PASSWORD"
    cat
  } | docker compose exec -T db psql -U postgres -d "$DB_NAME" -X -q -v ON_ERROR_STOP=1 --single-transaction \
    -f - | tr -d '\r'
}

apply_file() {
  local file="$1" version checksum
  [ -f "$file" ] || die "no such migration: $file"
  version="$(version_of "$file")"
  checksum="$(checksum_of "$file")"
  is_applied "$version" && die "version $version is already applied"
  {
    cat "$file"
    printf "\ninsert into public.schema_migrations (version, file, checksum) values ('%s', '%s', '%s');\n" \
      "$version" "$file" "$checksum"
    printf "notify pgrst, 'reload schema';\n"
  } | run_in_tx
  ok "applied $version ($(basename "$file"))"
}

pre_deploy_backup() {
  if [ -n "$(sql "select 1 from information_schema.schemata where schema_name = 'core'")" ]; then
    info "taking pre-deploy backup"
    "$ROOT/scripts/backup.sh" "pre-deploy-$1" | sed 's/^/  /'
  fi
}

check_drift() {
  local file version recorded
  for file in db/migrations/[0-9]*.sql; do
    case "$file" in *.down.sql) continue ;; esac
    version="$(version_of "$file")"
    recorded="$(sql "select checksum from public.schema_migrations where version = '$version'")"
    if [ -n "$recorded" ] && [ "$recorded" != "$(checksum_of "$file")" ]; then
      warn "$file changed after it was applied (checksum drift). Write a new migration instead."
    fi
  done
}

cmd_up() {
  ensure_table
  check_drift
  local pending=() file
  for file in db/migrations/[0-9]*.sql; do
    case "$file" in *.down.sql) continue ;; esac
    is_applied "$(version_of "$file")" || pending+=("$file")
  done
  if [ "${#pending[@]}" -eq 0 ]; then ok "database is up to date"; return; fi
  pre_deploy_backup "$(version_of "${pending[0]}")"
  for file in "${pending[@]}"; do apply_file "$file"; done
}

cmd_apply() {
  ensure_table
  [ $# -eq 1 ] || die "usage: migrate.sh apply <file>"
  pre_deploy_backup "$(version_of "$1")"
  apply_file "$1"
}

cmd_down() {
  ensure_table
  local row version file down
  row="$(sql "select version || '|' || file from public.schema_migrations order by version desc limit 1")"
  [ -n "$row" ] || die "nothing to roll back"
  version="${row%%|*}"; file="${row#*|}"; down="${file%.sql}.down.sql"
  [ -f "$down" ] || die "no rollback script for $version (expected $down)"
  info "taking pre-rollback backup"
  "$ROOT/scripts/backup.sh" "pre-rollback-$version" | sed 's/^/  /'
  {
    cat "$down"
    printf "\ndelete from public.schema_migrations where version = '%s';\n" "$version"
    printf "notify pgrst, 'reload schema';\n"
  } | run_in_tx
  ok "rolled back $version ($(basename "$file"))"
}

cmd_status() {
  ensure_table
  sql_table "select version, file, left(checksum, 12) as checksum,
                    to_char(applied_at at time zone 'Asia/Dubai', 'YYYY-MM-DD HH24:MI:SS') as applied_gst
               from public.schema_migrations order by version"
}

case "${1:-status}" in
  up) cmd_up ;;
  apply) shift; cmd_apply "$@" ;;
  down) cmd_down ;;
  status) cmd_status ;;
  *) die "usage: migrate.sh up | apply <file> | down | status" ;;
esac
