# shellcheck shell=bash

say() { printf 'supabase-backup: %s\n' "$*" >&2; }

err() {
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    printf '::error title=supabase-backup::%s\n' "$*"
  else
    printf 'supabase-backup: error: %s\n' "$*" >&2
  fi
}

warn() {
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    printf '::warning title=supabase-backup::%s\n' "$*"
  else
    printf 'supabase-backup: warning: %s\n' "$*" >&2
  fi
}

output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
  fi
}

summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"
  fi
}

masked_url() {
  printf '%s' "$1" | sed -E 's#^(postgres(ql)?://).*@#\1***@#'
}

check_files() {
  local dir="$1" f
  for f in roles schema data; do
    if [ ! -s "$dir/$f.sql" ]; then
      err "$dir/$f.sql is missing or empty."
      return 1
    fi
  done
  if ! grep -q '^-- PostgreSQL database dump complete' "$dir/data.sql"; then
    err "data.sql has no 'PostgreSQL database dump complete' line, so the file was cut off before its end."
    return 1
  fi
  if ! grep -q '^COPY "auth"\."users" ' "$dir/data.sql"; then
    err "data.sql has no COPY \"auth\".\"users\" block, so your users are not in this backup."
    return 1
  fi
}

# Statements on Supabase's own roles that the CLI leaves in roles.sql and a new project refuses.
fix_roles_sql() {
  local file="$1" n
  local reserved='anon|authenticated|authenticator|cli_login_[^"]*|dashboard_user|pgbouncer|postgres|service_role|supabase_[^"]*|pgsodium_keyholder|pgsodium_keyiduser|pgsodium_keymaker|pgtle_admin'
  # supautils.reserved_roles without a trailing *: nobody but a superuser may alter them.
  local locked='cli_login_[^"]*|dashboard_user|pgbouncer|supabase_[^"]*'
  local pattern="^(GRANT .* ON PARAMETER .* TO \"($reserved)\"|ALTER ROLE \"($locked)\" )"
  n="$(grep -c -E "$pattern" "$file" || true)"
  if [ "$n" -gt 0 ]; then
    sed -E "s/$pattern.*$/-- &/" "$file" >"$file.tmp" && mv "$file.tmp" "$file"
  fi
  printf '%s\n' "$n"
}

# table<TAB>rows for each COPY block
copy_counts() {
  awk '
    /^COPY .* FROM stdin;$/ {
      t = substr($0, 6)
      i = index(t, " (")
      if (i == 0) i = index(t, " FROM stdin;")
      t = substr(t, 1, i - 1)
      n = 0
      inside = 1
      next
    }
    inside && $0 == "\\." { print t "\t" n; inside = 0; next }
    inside { n++ }
  ' "$1"
}

pg_major_of_dump() {
  sed -n 's/^-- Dumped from database version \([0-9][0-9]*\).*/\1/p' "$1" | head -n 1
}

# $1: copy_counts output, $2: restored counts in the same order
count_mismatches() {
  paste "$1" "$2" | awk -F '\t' '$2 != $3 { print $1 "\t" $2 "\t" ($3 == "" ? "?" : $3) }'
}
