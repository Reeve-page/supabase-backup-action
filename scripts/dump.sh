#!/usr/bin/env bash
# Dump a Supabase database as roles, schema and data, the three files Supabase's
# backup-restore guide prescribes. A restore replays them in that order.

set -euo pipefail

if [ -z "${SUPABASE_DB_URL:-}" ]; then
  echo "supabase-backup-action: SUPABASE_DB_URL is empty. Pass the Session pooler string from your project's Connect button as a secret." >&2
  exit 1
fi

if ! command -v supabase >/dev/null 2>&1; then
  echo "supabase-backup-action: the Supabase CLI is not on PATH." >&2
  echo "  Add 'uses: supabase/setup-cli@v1' before this step." >&2
  exit 1
fi

OUT="${SUPABASE_BACKUP_DIR:-supabase-backup}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"

ROLES="$OUT/roles-$STAMP.sql"
SCHEMA="$OUT/schema-$STAMP.sql"
DATA="$OUT/data-$STAMP.sql"

# Log the target with the password masked.
printf 'supabase-backup-action: dumping %s\n' "$(printf '%s' "$SUPABASE_DB_URL" | sed -E 's#^(postgres(ql)?://)[^:]+:[^@]+@#\1***:***@#')" >&2

supabase db dump --db-url "$SUPABASE_DB_URL" -f "$ROLES" --role-only
supabase db dump --db-url "$SUPABASE_DB_URL" -f "$SCHEMA"
# The vector tables don't replay, so the guide leaves them out.
supabase db dump --db-url "$SUPABASE_DB_URL" -f "$DATA" --use-copy --data-only \
  -x "storage.buckets_vectors" -x "storage.vector_indexes"

# Low floors: they only catch a dump that exists and holds nothing.
floor() {
  local file="$1" min="$2" size
  size=$(wc -c <"$file")
  if [ "$size" -lt "$min" ]; then
    echo "supabase-backup-action: $file is $size bytes, under the $min-byte floor. Treating this as a failed dump." >&2
    exit 1
  fi
  printf 'supabase-backup-action: %s %s bytes\n' "$file" "$size" >&2
}

floor "$ROLES" 200
floor "$SCHEMA" 1000
floor "$DATA" 100

# COPY blocks exist even for empty tables, so this proves the auth schema was
# dumped without requiring any users.
if ! grep -q '^COPY auth\.users ' "$DATA"; then
  echo "supabase-backup-action: no 'COPY auth.users' block in $DATA." >&2
  echo "  The data dump did not reach the auth schema, so this is not a backup you can restore your users from." >&2
  exit 1
fi

echo "supabase-backup-action: auth.users is in the data dump" >&2

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "files=$ROLES $SCHEMA $DATA" >>"$GITHUB_OUTPUT"
  echo "dir=$OUT" >>"$GITHUB_OUTPUT"
fi
