#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

dir="${BACKUP_DIR:?}"
stamp="${BACKUP_STAMP:?}"
bucket="${S3_BUCKET:-}"
prefix="${S3_PREFIX-supabase-backups/}"
endpoint="${S3_ENDPOINT:-}"

if [ -z "$bucket" ]; then
  err "s3-bucket is empty."
  exit 1
fi
if ! command -v aws >/dev/null 2>&1; then
  err "Uploading to S3 needs the AWS CLI on PATH. GitHub's Ubuntu runners have it."
  exit 1
fi

if [ -n "${S3_ACCESS_KEY_ID:-}" ]; then export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"; fi
if [ -n "${S3_SECRET_ACCESS_KEY:-}" ]; then export AWS_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"; fi
region="${S3_REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"
if [ -z "$region" ]; then
  if [ -n "$endpoint" ]; then region=auto; else region=us-east-1; fi
fi
export AWS_REGION="$region" AWS_DEFAULT_REGION="$region"

if [ -n "$prefix" ] && [ "${prefix%/}" = "$prefix" ]; then prefix="$prefix/"; fi
dest="s3://$bucket/${prefix#/}$stamp/"

args=(s3 cp "$dir" "$dest" --recursive --only-show-errors)
if [ -n "$endpoint" ]; then args+=(--endpoint-url "$endpoint"); fi

say "uploading to $dest"
if ! aws "${args[@]}"; then
  err "Upload to $dest failed."
  exit 1
fi

output uri "$dest"
summary "Backup kept at \`$dest\`."
