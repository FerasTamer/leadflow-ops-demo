#!/usr/bin/env bash
# Consistent logical backup with checksum, manifest and retention.
#
#   scripts/backup.sh [label]
#
# Produces in ./backups:
#   <name>.dump           pg_dump custom format (compressed, selective restore possible)
#   <name>.dump.sha256    integrity check, verified before any restore
#   <name>.globals.sql    roles and grants (cluster-level objects pg_dump does not include)
#   <name>.manifest       facts the restore must reproduce exactly (row counts, checksum, watermarks, RLS)
# Keeps the newest $BACKUP_KEEP backups (default 14) and deletes older ones.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env

label="${1:-manual}"
case "$label" in *[!A-Za-z0-9._-]*) die "label may only contain letters, digits, dot, dash, underscore" ;; esac
name="leadflow_$(date -u +%Y%m%dT%H%M%SZ)_${label}"
mkdir -p backups

# The manifest is taken right before and right after the dump. If the data changed in between
# (a sync ran mid-backup), the dump and the manifest might disagree, so we retry.
for attempt in 1 2 3; do
  before="$(manifest_of)"
  docker compose exec -T db sh -euc "
    cd /backups
    pg_dump -U postgres -d $DB_NAME -Fc -f $name.dump
    pg_dumpall -U postgres --globals-only --no-role-passwords -f $name.globals.sql
    sha256sum $name.dump > $name.dump.sha256
  "
  after="$(manifest_of)"
  if [ "$before" = "$after" ]; then break; fi
  warn "data changed during backup (attempt $attempt), retrying"
  [ "$attempt" -eq 3 ] && die "could not take a consistent backup"
done

printf '%s\n' "$after" > "backups/$name.manifest"
size="$(docker compose exec -T db sh -c "du -h /backups/$name.dump | cut -f1" | tr -d '\r')"
ok "backup $name ($size, sha256 $(cut -c1-12 "backups/$name.dump.sha256"))"

keep="${BACKUP_KEEP:-14}"
old="$(ls -1t backups/leadflow_*.dump 2>/dev/null | tail -n +"$((keep + 1))" || true)"
for dump in $old; do
  base="${dump%.dump}"
  rm -f "$dump" "$dump.sha256" "$base.globals.sql" "$base.manifest"
  info "retention: removed $(basename "$base")"
done
echo "$name"
