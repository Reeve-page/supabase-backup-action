#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

url="${SUPABASE_DB_URL:-}"
destination="${BACKUP_DESTINATION:-artifact}"
verify="${BACKUP_VERIFY:-true}"

if [ -z "$url" ]; then
  err "db-url is empty. Pass the Session pooler string from your project's Connect button as a secret."
  exit 1
fi
case "$destination" in
  artifact | none) ;;
  s3)
    if [ -z "${BACKUP_S3_BUCKET:-}" ]; then
      err "destination is s3 but s3-bucket is empty."
      exit 1
    fi
    ;;
  *)
    err "destination must be artifact, s3 or none, not '$destination'."
    exit 1
    ;;
esac
case "$verify" in
  true | false) ;;
  *)
    err "verify must be true or false, not '$verify'."
    exit 1
    ;;
esac
if ! command -v supabase >/dev/null 2>&1; then
  err "The Supabase CLI is not on PATH."
  exit 1
fi

host="$(printf '%s' "$url" | sed -E 's#^[^/]*//(.*@)?([^:/?]+).*#\2#')"
say "dumping $(masked_url "$url")"

# pg_dump 17 output doesn't restore into Postgres 15, so match the server.
major="${BACKUP_PG_MAJOR:-}"
major="${major%%.*}"
if [ -z "$major" ]; then
  num=""
  if command -v psql >/dev/null 2>&1; then
    num="$(PGCONNECT_TIMEOUT=20 psql -X -A -t -c 'show server_version_num' -d "$url" 2>/dev/null || true)"
  fi
  if [[ "$num" =~ ^[0-9]+$ ]]; then
    major=$((num / 10000))
  else
    warn "Could not read the server's Postgres version, so pg_dump is the Supabase CLI's default. Set postgres-version if your project runs Postgres 15."
  fi
fi
if [ -n "$major" ]; then
  if ! [[ "$major" =~ ^[0-9]+$ ]]; then
    err "postgres-version must be a number such as 15 or 17, not '${BACKUP_PG_MAJOR:-}'."
    exit 1
  fi
  export SUPABASE_DB_MAJOR_VERSION="$major"
  say "Postgres $major"
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${BACKUP_PATH:-supabase-backup}/$stamp"
out="$(cd "${BACKUP_PATH:-supabase-backup}/$stamp" && pwd)"

# Empty workdir so the caller's supabase/config.toml is ignored.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

dump() {
  local what="$1"
  shift
  say "dumping $what"
  if ! supabase db dump --workdir "$work" --db-url "$url" "$@"; then
    err "supabase db dump failed on the $what."
    if [[ "$host" =~ ^db\..+\.supabase\.co$ ]]; then
      err "db-url uses the direct connection ($host), which GitHub's runners can't reach over IPv6. Use the Session pooler string from your project's Connect button."
    fi
    exit 1
  fi
}

dump roles -f "$out/roles.sql" --role-only
dump schema -f "$out/schema.sql"
# Same exclusions as Supabase's guide.
dump data -f "$out/data.sql" --use-copy --data-only \
  -x "storage.buckets_vectors" -x "storage.vector_indexes"

n="$(comment_reserved_grants "$out/roles.sql")"
if [ "$n" != 0 ]; then say "roles.sql: commented out $n parameter grants to Supabase's own roles"; fi

check_files "$out"

for f in roles schema data; do
  say "$f.sql $(wc -c <"$out/$f.sql") bytes"
done
users="$(copy_counts "$out/data.sql" | awk -F '\t' '$1 == "\"auth\".\"users\"" { print $2 }')"
say "auth.users: ${users:-0} rows in the dump"

output dir "$out"
output files "$out/roles.sql $out/schema.sql $out/data.sql"
output stamp "$stamp"
output postgres-major "${major:-}"
