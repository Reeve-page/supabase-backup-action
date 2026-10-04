#!/usr/bin/env bash
# Replay a backup into a throwaway Supabase database and count what came back.
# Exits 0 when it passed, 1 when the backup failed, 2 when the check could not run.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

unchecked() {
  err "$1"
  output result unchecked
  summary "### ⚠️ Restore check could not run"
  summary ""
  summary "$1"
  exit 2
}

dir="${1:-}"
if [ -z "$dir" ] || [ ! -d "$dir" ]; then
  unchecked "check.sh needs the folder holding roles.sql, schema.sql and data.sql."
fi
dir="$(cd "$dir" && pwd)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

if ! check_files "$dir"; then
  output result failed
  summary "### ❌ Restore check failed"
  summary ""
  summary "The files failed before the restore. The error above says which check."
  exit 1
fi

major="$(pg_major_of_dump "$dir/data.sql")"
major="${major:-${SUPABASE_DB_MAJOR_VERSION:-}}"
if [ -z "$major" ]; then
  unchecked "data.sql does not say which Postgres version it came from."
fi
if ! command -v psql >/dev/null 2>&1; then
  unchecked "The restore check needs psql on PATH."
fi

url="${BACKUP_CHECK_TARGET_URL:-}"
if [ -z "$url" ]; then
  for tool in supabase docker; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      unchecked "The restore check needs $tool on PATH."
    fi
  done
  project="supabase-backup-check"
  port="${BACKUP_CHECK_PORT:-54398}"
  work="$tmp/project"
  mkdir -p "$work"
  cleanup() {
    supabase stop --project-id "$project" --no-backup --workdir "$work" >/dev/null 2>&1 || true
    rm -rf "$tmp"
  }
  (cd "$work" && supabase init >/dev/null)
  export SUPABASE_PROJECT_ID="$project" SUPABASE_DB_PORT="$port" SUPABASE_DB_MAJOR_VERSION="$major"
  say "starting a throwaway Supabase database on Postgres $major"
  if ! supabase db start --workdir "$work"; then
    unchecked "supabase db start failed, so there was nowhere to restore the backup."
  fi
  url="postgresql://postgres:postgres@127.0.0.1:$port/postgres"
fi

if ! own="$(psql -X -A -t -v ON_ERROR_STOP=1 -d "$url" -c "select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind in ('r', 'p')" 2>"$tmp/err")"; then
  unchecked "Could not connect to the throwaway database: $(head -n 1 "$tmp/err")"
fi
if [ "$own" != 0 ]; then
  unchecked "The check only restores into an empty database, and this one already has tables in public."
fi

# Restored cron jobs would otherwise start running in the throwaway database.
pause_cron="DO \$\$ BEGIN IF to_regclass('cron.job') IS NOT NULL THEN UPDATE cron.job SET active = false; END IF; END \$\$"

say "replaying the backup with the psql command from Supabase's restore guide"
started=$SECONDS
if ! psql -X --quiet --single-transaction --variable ON_ERROR_STOP=1 \
  --file "$dir/roles.sql" \
  --file "$dir/schema.sql" \
  --command 'SET session_replication_role = replica' \
  --file "$dir/data.sql" \
  --command "$pause_cron" \
  --dbname "$url" >"$tmp/replay.log" 2>&1; then
  first="$(grep -m 1 -E 'ERROR|FATAL' "$tmp/replay.log" || tail -n 1 "$tmp/replay.log")"
  err "The backup did not restore. $first"
  tail -n 20 "$tmp/replay.log" >&2
  output result failed
  {
    printf '# Restore check %s: failed. Postgres %s.\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$major"
    printf '# %s\n' "$first"
  } >"$dir/restore-check.tsv"
  summary "### ❌ Restore check failed"
  summary ""
  summary "The backup did not replay into a fresh Supabase database (Postgres $major):"
  summary ""
  summary '```'
  summary "$first"
  summary '```'
  summary ""
  summary "Supabase's [restore guide](https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore#troubleshooting-notes) covers the common errors."
  exit 1
fi
seconds=$((SECONDS - started))

copy_counts "$dir/data.sql" >"$tmp/want"
# row_security off makes a policy that would hide rows an error instead of a short count.
{
  printf 'SET row_security = off;\n'
  awk -F '\t' '{ printf "%sSELECT %d AS i, count(*) AS n FROM %s\n", (NR > 1 ? "UNION ALL " : ""), NR, $1 } END { print "ORDER BY i;" }' "$tmp/want"
} >"$tmp/count.sql"
if ! psql -X -q -A -t -F $'\t' -v ON_ERROR_STOP=1 -d "$url" -f "$tmp/count.sql" >"$tmp/counted" 2>"$tmp/err"; then
  unchecked "The backup restored, but counting its tables failed: $(head -n 1 "$tmp/err")"
fi
cut -f 2 "$tmp/counted" >"$tmp/got"
count_mismatches "$tmp/want" "$tmp/got" >"$tmp/bad" || true

tables="$(wc -l <"$tmp/want" | tr -d ' ')"
rows="$(awk -F '\t' '{ s += $2 } END { print s + 0 }' "$tmp/want")"
users="$(awk -F '\t' '$1 == "\"auth\".\"users\"" { print $2 }' "$tmp/want")"
if [ -s "$tmp/bad" ]; then result=failed; else result=passed; fi

{
  printf '# Restore check %s: %s. Postgres %s, %s tables, %s rows.\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$result" "$major" "$tables" "$rows"
  printf 'table\trows_in_file\trows_restored\n'
  paste "$tmp/want" "$tmp/got"
} >"$dir/restore-check.tsv"

md_rows() {
  awk -F '\t' '{ gsub(/\|/, "\\|", $1); printf "| `%s` | %s | %s |\n", $1, $2, $3 }'
}

if [ "$result" = failed ]; then
  err "$(wc -l <"$tmp/bad" | tr -d ' ') tables came back with a different row count than the file holds."
  cat "$tmp/bad" >&2
  output result failed
  summary "### ❌ Restore check failed"
  summary ""
  summary "The backup replayed, but these tables came back with a different number of rows than data.sql holds:"
  summary ""
  summary "| Table | Rows in the file | Rows restored |"
  summary "| --- | --: | --: |"
  summary "$(head -n 50 "$tmp/bad" | md_rows)"
  exit 1
fi

say "passed: $tables tables, $rows rows, auth.users ${users:-0}, replayed in ${seconds}s"
output result passed
summary "### ✅ Restore check passed"
summary ""
summary "Replayed into a throwaway Supabase database (Postgres $major) in ${seconds}s. $tables tables and $rows rows came back, every count matching data.sql. Your users: ${users:-0} rows in \`auth.users\`."
summary ""
summary "| Table | Rows in the file | Rows restored |"
summary "| --- | --: | --: |"
summary "$(paste "$tmp/want" "$tmp/got" | sort -t $'\t' -k 2,2nr | head -n 30 | md_rows)"
if [ "$tables" -gt 30 ]; then
  summary ""
  summary "The 30 largest of $tables tables. All of them are in \`restore-check.tsv\`, saved with the backup."
fi
