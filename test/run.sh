#!/usr/bin/env bash
# Needs a Postgres superuser: TEST_PGHOST, TEST_PGPORT, TEST_PGUSER, TEST_PGPASSWORD.
set -uo pipefail

unset GITHUB_ACTIONS GITHUB_OUTPUT GITHUB_STEP_SUMMARY

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scripts="$root/scripts"
fixtures="$root/test/fixtures"
# shellcheck source=../scripts/lib.sh
. "$scripts/lib.sh"

host="${TEST_PGHOST:-127.0.0.1}"
port="${TEST_PGPORT:-5432}"
user="${TEST_PGUSER:-postgres}"
pass="${TEST_PGPASSWORD:-}"
url_for() { printf 'postgresql://%s%s@/%s?host=%s&port=%s' "$user" "${pass:+:$pass}" "$1" "$host" "$port"; }

tmp="$(mktemp -d)"
src="backup_test_src_$$"
dst="backup_test_dst_$$"
admin="$(url_for postgres)"
cleanup() {
  psql -X -q -d "$admin" -c "DROP DATABASE IF EXISTS $src" -c "DROP DATABASE IF EXISTS $dst" >/dev/null 2>&1
  rm -rf "$tmp"
}
trap cleanup EXIT

sql() { psql -X -q -v ON_ERROR_STOP=1 -d "$@" >/dev/null; }

fresh_dst() {
  sql "$admin" -c "DROP DATABASE IF EXISTS $dst" -c "CREATE DATABASE $dst" &&
    sql "$(url_for "$dst")" -f "$fixtures/auth.sql"
}

make_backup() {
  local out="$1" schemas="${2:---schema public --schema auth}"
  mkdir -p "$out"
  printf 'SET client_min_messages = warning;\nRESET ALL;\n' >"$out/roles.sql"
  pg_dump --schema-only --quote-all-identifier --schema public -d "$(url_for "$src")" |
    sed -E -e 's/^CREATE SCHEMA "/CREATE SCHEMA IF NOT EXISTS "/' -e '/^--/d' >"$out/schema.sql"
  {
    printf 'SET session_replication_role = replica;\n\n'
    # shellcheck disable=SC2086
    pg_dump --data-only --quote-all-identifier $schemas -d "$(url_for "$src")"
    printf 'RESET ALL;\n'
  } >"$out/data.sql"
}

passed=0
failed=0
t() {
  local name="$1"
  shift
  if out="$("$@" 2>&1)"; then
    passed=$((passed + 1))
    printf 'ok   %s\n' "$name"
  else
    failed=$((failed + 1))
    printf 'FAIL %s\n%s\n' "$name" "$out" | sed '2,$s/^/     /'
  fi
}

expect() {
  if [ "$1" != "$2" ]; then
    printf 'expected: %s\n     got: %s\n' "$2" "$1"
    return 1
  fi
}

contains() {
  if ! grep -qF -- "$2" "$1"; then
    printf '%s does not contain: %s\n' "$1" "$2"
    sed 's/^/  | /' "$1"
    return 1
  fi
}

sql "$admin" -c "CREATE DATABASE $src" || exit 1
sql "$(url_for "$src")" -f "$fixtures/auth.sql" -f "$fixtures/source.sql" || exit 1
make_backup "$tmp/good"

test_copy_counts() {
  expect "$(copy_counts "$tmp/good/data.sql" | sort)" "$(printf '%s\n' \
    $'"auth"."users"\t3' $'"public"."Odd name"\t2' $'"public"."empty"\t0' \
    $'"public"."notes"\t6' $'"public"."orders"\t300' | sort)"
}

test_pg_major() {
  local server
  server="$(psql -X -A -t -d "$(url_for "$src")" -c 'show server_version_num')"
  expect "$(pg_major_of_dump "$tmp/good/data.sql")" "$((server / 10000))"
}

test_count_mismatches() {
  printf 'a\t3\nb\t5\nc\t0\n' >"$tmp/want"
  printf '3\n4\n' >"$tmp/got"
  expect "$(count_mismatches "$tmp/want" "$tmp/got")" $'b\t5\t4\nc\t0\t?'
}

test_masked_url() {
  expect "$(masked_url 'postgresql://postgres.abc:p@ss:w@aws-0-eu-west-1.pooler.supabase.com:5432/postgres')" \
    'postgresql://***@aws-0-eu-west-1.pooler.supabase.com:5432/postgres'
}

test_files_good() { check_files "$tmp/good"; }

test_fix_roles_sql() {
  printf '%s\n' 'CREATE ROLE "app_admin";' \
    'GRANT SET ON PARAMETER "log_min_messages" TO "supabase_realtime_admin";' \
    'GRANT SET,ALTER SYSTEM ON PARAMETER "log_min_messages" TO "postgres";' \
    'GRANT SET ON PARAMETER "log_min_messages" TO "app_admin";' \
    'ALTER ROLE "supabase_admin" SET "statement_timeout" TO '"'0'"';' \
    'ALTER ROLE "authenticator" SET "statement_timeout" TO '"'8s'"';' \
    'ALTER ROLE "app_admin" SET "statement_timeout" TO '"'1min'"';' >"$tmp/roles.sql"
  expect "$(fix_roles_sql "$tmp/roles.sql")" 3 &&
    expect "$(cat "$tmp/roles.sql")" "$(printf '%s\n' 'CREATE ROLE "app_admin";' \
      '-- GRANT SET ON PARAMETER "log_min_messages" TO "supabase_realtime_admin";' \
      '-- GRANT SET,ALTER SYSTEM ON PARAMETER "log_min_messages" TO "postgres";' \
      'GRANT SET ON PARAMETER "log_min_messages" TO "app_admin";' \
      '-- ALTER ROLE "supabase_admin" SET "statement_timeout" TO '"'0'"';' \
      'ALTER ROLE "authenticator" SET "statement_timeout" TO '"'8s'"';' \
      'ALTER ROLE "app_admin" SET "statement_timeout" TO '"'1min'"';')" &&
    expect "$(fix_roles_sql "$tmp/roles.sql")" 0
}

test_files_cut() {
  cp -r "$tmp/good" "$tmp/cut"
  local keep
  keep="$(grep -n '^COPY "public"."orders"' "$tmp/cut/data.sql" | cut -d: -f1)"
  head -n "$((keep + 100))" "$tmp/good/data.sql" >"$tmp/cut/data.sql"
  ! check_files "$tmp/cut" 2>"$tmp/err" && contains "$tmp/err" "cut off"
}

test_files_no_users() {
  make_backup "$tmp/nousers" "--schema public"
  ! check_files "$tmp/nousers" 2>"$tmp/err" && contains "$tmp/err" 'no COPY "auth"."users"'
}

run_check() {
  local dir="$1"
  : >"$tmp/out"
  : >"$tmp/summary"
  GITHUB_OUTPUT="$tmp/out" GITHUB_STEP_SUMMARY="$tmp/summary" BACKUP_CHECK_TARGET_URL="$(url_for "$dst")" \
    "$scripts/check.sh" "$dir" >"$tmp/log" 2>&1
}

test_check_passes() {
  fresh_dst || return 1
  run_check "$tmp/good"
  expect "$?" 0 || { cat "$tmp/log"; return 1; }
  contains "$tmp/out" "result=passed" &&
    contains "$tmp/summary" "Restore check passed" &&
    contains "$tmp/good/restore-check.tsv" $'"public"."orders"\t300\t300' &&
    contains "$tmp/good/restore-check.tsv" $'"auth"."users"\t3\t3' &&
    contains "$tmp/good/restore-check.tsv" $'"public"."notes"\t6\t6'
}

test_check_restored_the_rows() {
  expect "$(psql -X -A -t -d "$(url_for "$dst")" -c "select body from public.notes where id = 2")" $'line one\nline two'
}

test_check_refuses_a_used_database() {
  run_check "$tmp/good"
  expect "$?" 2 && contains "$tmp/out" "result=unchecked" && contains "$tmp/log" "empty database"
}

test_check_cut_file() {
  fresh_dst || return 1
  run_check "$tmp/cut"
  expect "$?" 1 && contains "$tmp/out" "result=failed"
}

test_check_bad_schema() {
  fresh_dst || return 1
  cp -r "$tmp/good" "$tmp/badschema"
  rm -f "$tmp/badschema/restore-check.tsv"
  printf 'GRANT SELECT ON "public"."orders" TO "nobody_by_this_name";\n' >>"$tmp/badschema/schema.sql"
  run_check "$tmp/badschema"
  expect "$?" 1 &&
    contains "$tmp/out" "result=failed" &&
    contains "$tmp/log" 'role "nobody_by_this_name" does not exist' &&
    contains "$tmp/log" 'Statement: GRANT SELECT ON "public"."orders" TO "nobody_by_this_name";' &&
    contains "$tmp/log" 'schema.sql line ' &&
    contains "$tmp/badschema/restore-check.tsv" "failed"
}

test_check_rolled_back() {
  expect "$(psql -X -A -t -d "$(url_for "$dst")" -c "select count(*) from pg_tables where schemaname = 'public'")" 0
}

test_check_no_dir() {
  GITHUB_OUTPUT="$tmp/out" "$scripts/check.sh" "$tmp/nowhere" >"$tmp/log" 2>&1
  expect "$?" 2
}

# Fake supabase CLI.
stub_bin="$tmp/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/supabase" <<EOF
#!/usr/bin/env bash
printf '%s|%s\n' "\$*" "\${SUPABASE_DB_MAJOR_VERSION:-}" >>"$tmp/supabase.calls"
[ "\${STUB_FAIL:-}" = 1 ] && { echo 'failed to connect: network is unreachable' >&2; exit 1; }
while [ \$# -gt 0 ]; do
  case "\$1" in
    --workdir) [ -z "\$(ls -A "\$2")" ] || { echo 'workdir not empty' >&2; exit 3; }; shift ;;
    -f) file="\$2"; shift ;;
  esac
  shift
done
cp "$tmp/good/\$(basename "\$file")" "\$file"
EOF
chmod +x "$stub_bin/supabase"

run_dump() {
  : >"$tmp/out"
  : >"$tmp/supabase.calls"
  (cd "$tmp" && PATH="$stub_bin:$PATH" GITHUB_OUTPUT="$tmp/out" BACKUP_PATH="$tmp/backups" "$@" "$scripts/dump.sh") >"$tmp/log" 2>&1
}

test_dump_writes_the_three_files() {
  run_dump env SUPABASE_DB_URL="$(url_for "$src")"
  expect "$?" 0 || { cat "$tmp/log"; return 1; }
  local dir server
  dir="$(sed -n 's/^dir=//p' "$tmp/out")"
  server="$(psql -X -A -t -d "$(url_for "$src")" -c 'show server_version_num')"
  [ -s "$dir/roles.sql" ] && [ -s "$dir/schema.sql" ] && [ -s "$dir/data.sql" ] &&
    contains "$tmp/out" "postgres-major=$((server / 10000))" &&
    contains "$tmp/supabase.calls" "--role-only|$((server / 10000))" &&
    contains "$tmp/supabase.calls" '--use-copy --data-only -x storage.buckets_vectors -x storage.vector_indexes' &&
    contains "$tmp/log" "auth.users: 3 rows"
}

test_dump_refuses_bad_inputs() {
  run_dump env SUPABASE_DB_URL=
  expect "$?" 1 || return 1
  run_dump env SUPABASE_DB_URL=x BACKUP_DESTINATION=dropbox
  expect "$?" 1 && contains "$tmp/log" "artifact, s3 or none" || return 1
  run_dump env SUPABASE_DB_URL=x BACKUP_DESTINATION=s3
  expect "$?" 1 && contains "$tmp/log" "s3-bucket is empty" || return 1
  run_dump env SUPABASE_DB_URL=x BACKUP_VERIFY=yes
  expect "$?" 1 && contains "$tmp/log" "verify must be true or false" || return 1
  run_dump env SUPABASE_DB_URL=x BACKUP_PG_MAJOR=seventeen
  expect "$?" 1 && contains "$tmp/log" "postgres-version must be a number"
}

test_dump_hints_at_the_pooler() {
  run_dump env STUB_FAIL=1 BACKUP_PG_MAJOR=17 \
    SUPABASE_DB_URL='postgresql://postgres:pw@db.abcdefghijklmnopqrst.supabase.co:5432/postgres'
  expect "$?" 1 && contains "$tmp/log" "Session pooler" && ! grep -q 'pw@' "$tmp/log"
}

cat >"$stub_bin/aws" <<EOF
#!/usr/bin/env bash
printf '%s|%s|%s\n' "\$*" "\$AWS_REGION" "\${AWS_ACCESS_KEY_ID:-}" >>"$tmp/aws.calls"
EOF
chmod +x "$stub_bin/aws"

test_upload_s3() {
  : >"$tmp/aws.calls"
  : >"$tmp/out"
  PATH="$stub_bin:$PATH" GITHUB_OUTPUT="$tmp/out" BACKUP_DIR="$tmp/good" BACKUP_STAMP=20261004T031700Z \
    S3_BUCKET=backups S3_PREFIX=nightly S3_ENDPOINT=https://acct.r2.cloudflarestorage.com S3_ACCESS_KEY_ID=AKID \
    "$scripts/upload-s3.sh" >"$tmp/log" 2>&1
  expect "$?" 0 || { cat "$tmp/log"; return 1; }
  contains "$tmp/aws.calls" "s3 cp $tmp/good s3://backups/nightly/20261004T031700Z/ --recursive --only-show-errors --endpoint-url https://acct.r2.cloudflarestorage.com|auto|AKID" &&
    contains "$tmp/out" "uri=s3://backups/nightly/20261004T031700Z/"
}

for name in copy_counts pg_major count_mismatches masked_url \
  files_good fix_roles_sql files_cut files_no_users \
  check_passes check_restored_the_rows check_refuses_a_used_database check_cut_file \
  check_bad_schema check_rolled_back check_no_dir \
  dump_writes_the_three_files dump_refuses_bad_inputs dump_hints_at_the_pooler upload_s3; do
  t "$name" "test_$name"
done

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = 0 ]
