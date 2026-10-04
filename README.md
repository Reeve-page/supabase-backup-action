# Supabase backup with a restore check

A GitHub Action that backs up a Supabase database on a schedule and keeps the
copy outside Supabase. Then it restores that copy into a throwaway Supabase
database on the runner and counts every table against the file.

A plain backup workflow turns green when the dump command exits 0. A file that
was cut off halfway, a dump with no rows in it and a dump without your users all
exit 0 as well. This run turns green only when the copy restored and every table
came back with the rows the file holds.

```yaml
- uses: reeve-page/supabase-backup-action@v1
  with:
    db-url: ${{ secrets.SUPABASE_DB_URL }}
```

## Quick start

1. Create a **private** repository for the backups. The data file holds your
   users' email addresses, so give it a repository of its own.
2. In your Supabase project, click **Connect** and copy the **Session pooler**
   string. Its user is `postgres.<project-ref>`, its host ends in
   `pooler.supabase.com`, and its port is `5432`. Put your database password
   into it.
3. In the repository, open Settings, then Secrets and variables, then Actions,
   and add a secret called `SUPABASE_DB_URL` holding that string.
4. Save [`examples/backup.yml`](examples/backup.yml) as
   `.github/workflows/supabase-backup.yml`.
5. Run it once by hand from the Actions tab, so the first run happens while you
   are watching.

The direct connection string (`db.<project-ref>.supabase.co`) fails on GitHub's
runners: it uses IPv6 unless you pay for the IPv4 add-on, and the runners only
reach IPv4. Supabase's
[backup and restore guide](https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore)
says to use the Session pooler string by default.

## What a run does

1. **Dumps** roles, schema and data into `roles.sql`, `schema.sql` and
   `data.sql` with the three `supabase db dump` commands from Supabase's backup
   and restore guide. The action reads your project's Postgres version from the
   server first, and the Supabase CLI runs the `pg_dump` for that version.
   On Postgres 17, `roles.sql` also gets grants of settings to Supabase's own
   roles. The CLI misses those, and they stop Supabase's restore command, so
   the action comments them out the way the CLI handles those roles' other
   lines.
2. **Checks the files.** `data.sql` must end with pg_dump's
   `PostgreSQL database dump complete` line, which a file cut off partway never
   has. It must also hold a `COPY "auth"."users"` block, where your accounts
   live.
3. **Restores them** into a fresh Supabase database on the runner
   (`supabase db start`, on your project's Postgres major version), with the
   `psql` command from the same guide.
4. **Counts** the rows of every table in the restored database and compares
   each count with the rows `data.sql` holds for that table. The result goes
   into `restore-check.tsv` beside the three files and into the run's summary.
5. **Keeps** the folder as a workflow artifact, in an S3-compatible bucket, or
   in the workspace for your own steps.
6. **Fails the run** when the check did not pass. The copy is kept either way.

## Inputs

| Input                  | Default             | What it does                                                                                                       |
| ---------------------- | ------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `db-url`               | (required)          | The Session pooler connection string, from a secret.                                                               |
| `destination`          | `artifact`          | `artifact`, `s3`, or `none` to leave the files in the workspace.                                                   |
| `retention-days`       | `7`                 | Days GitHub keeps the artifact.                                                                                    |
| `s3-bucket`            |                     | Bucket name, when `destination` is `s3`.                                                                           |
| `s3-prefix`            | `supabase-backups/` | Each run writes to `<prefix><timestamp>/`.                                                                         |
| `s3-endpoint`          |                     | For a store that is not AWS, e.g. `https://<account-id>.r2.cloudflarestorage.com`.                                 |
| `s3-region`            |                     | `auto` when `s3-endpoint` is set, otherwise `AWS_REGION` or `us-east-1`.                                           |
| `s3-access-key-id`     |                     | From a secret. Leave empty to use credentials already in the job, such as `aws-actions/configure-aws-credentials`. |
| `s3-secret-access-key` |                     | From a secret.                                                                                                     |
| `verify`               | `true`              | `false` skips the restore check.                                                                                   |
| `postgres-version`     |                     | Your project's Postgres major version. Leave it empty and the action reads it from the server.                     |
| `path`                 | `supabase-backup`   | Folder in the workspace the files are written to, one timestamped folder per run.                                  |
| `cli-version`          | `latest`            | Supabase CLI version.                                                                                              |

## Outputs

| Output         | Value                                                                             |
| -------------- | --------------------------------------------------------------------------------- |
| `dir`          | The folder holding the three files and `restore-check.tsv`.                       |
| `files`        | The three files, space-separated.                                                 |
| `check`        | `passed`, `failed`, `unchecked` when the check could not run, `skipped` when off. |
| `artifact-url` | Download URL of the artifact.                                                     |
| `s3-uri`       | Where the copy landed in the bucket.                                              |

## Where the copy goes

**As an artifact** (the default), the folder is zipped and kept with the run for
`retention-days`. On a private repository, artifacts count against your
account's storage: GitHub Free includes
[500 MB](https://docs.github.com/en/billing/concepts/product-billing/github-actions),
shared with GitHub Packages, and once an account with no payment method uses it
up, further use is blocked. Seven nightly copies take seven times the zipped
size of one, so look at the size of the first artifact before you raise the
retention.

**In a bucket**, any S3-compatible store works: AWS S3, Cloudflare R2,
Backblaze B2, MinIO. [`examples/backup-r2.yml`](examples/backup-r2.yml) is the
R2 version. Give the key write access to that one bucket and nothing else, and
set a lifecycle rule on the bucket to delete old copies, because the action
never deletes anything.

**With `none`**, the files stay in the workspace at the `dir` output for steps
of your own, such as committing them to the repository.

## What it costs

Every run downloads your whole database, and Supabase counts that download as
egress, against an allowance shared by every project in the organization. On
4 October 2026 [Supabase's pricing page](https://supabase.com/pricing) gave the
free plan 5 GB of egress a month and a 500 MB database per project, and Pro
250 GB of egress. A daily backup of a 500 MB database moves about 15 GB a month,
three times the free allowance before your app has served a request. Weekly
fits at every size the free plan allows:

```yaml
- cron: '17 3 * * 0' # Sundays
```

[The arithmetic for every size](https://reeve.page/blog/supabase-backup-github-action)
is in the article this action grew out of.

The restore check runs entirely on the runner and downloads nothing from your
project. It costs runner minutes, which are free on public repositories and
count against your plan's minutes on private ones.

## What the check does not prove

- **That anyone can sign in.** The check proves the rows in `auth.users` came
  back. A sign-in against a restored copy is the only test of the passwords,
  and [the restore drill](https://reeve.page/blog/test-your-supabase-backup)
  shows how to run one.
- **Anything about uploaded files.** Supabase Storage keeps each file outside
  the database, so a dump holds the row describing a file and never the file.
  [Backing up Storage](https://reeve.page/blog/supabase-storage-backup) is a
  job of its own.
- **That encrypted columns decrypt.** Vault secrets and pgsodium columns restore
  as ciphertext, and the root key is never in a backup. Supabase's guide
  explains how to copy the key to a new project.
- **Your `pg_cron` jobs.** The extension comes back with the schema, but the
  jobs live in `cron.job`, whose rows pg_dump leaves out of this dump, so a
  restored project runs none of them. Keep your `cron.schedule` calls in a
  migration or a file you can run again.
- **Anything outside the database:** Edge Functions, auth provider settings,
  API keys and project settings.

The throwaway database runs the auth and storage versions that ship with the
Supabase CLI, which can be older than the ones your hosted project runs. If the
check fails on a column in `auth` or `storage` that does not exist, the CLI is
behind your project; keep `cli-version` at `latest`.

## When the check fails

The run's summary shows the first error, and the Restore check step has the
last twenty lines of the replay.

- **A permission error naming `supabase_admin` or `cli_login_postgres`.**
  Supabase's guide covers both in its
  [troubleshooting notes](https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore#troubleshooting-notes).
  A restore into a new project runs the same command, so expect it to stop at
  the same line.
- **`no 'PostgreSQL database dump complete' line`.** The dump was cut off.
  The dump step's log has the reason.
- **`no COPY "auth"."users" block`.** The data dump did not reach your users.
  The action's own dump always includes them, so this comes from a `data.sql`
  made some other way.
- **A table with fewer rows than the file holds.** The replay did not load
  what the file contains. The summary names the table.

`unchecked` means the check could not run at all, for example on a self-hosted
runner without Docker. It fails the run too, and the summary says what was
missing.

## Restoring a copy for real

Create a new Supabase project, download the copy, and replay it with the
command from Supabase's guide:

```bash
psql \
  --single-transaction \
  --variable ON_ERROR_STOP=1 \
  --file roles.sql \
  --file schema.sql \
  --command 'SET session_replication_role = replica' \
  --file data.sql \
  --dbname "<the new project's Session pooler string>"
```

[How to restore a Supabase backup](https://reeve.page/blog/how-to-restore-a-supabase-backup)
goes through it step by step.

## Checking a copy you already have

`scripts/check.sh <folder>` checks any folder holding the three files, on any
machine with Docker, `psql` and the Supabase CLI. It exits 0 when the copy
passed, 1 when it failed and 2 when it could not run.

## Writing behind it

- [Free Supabase backup with a GitHub Action, and the catch](https://reeve.page/blog/supabase-backup-github-action)
- [Test your Supabase backup before the day you need it](https://reeve.page/blog/test-your-supabase-backup)
- [Why your Supabase dump has no users in it](https://reeve.page/blog/supabase-backup-auth-users)

## Not running it yourself

[Reeve](https://reeve.page/supabase-backups) does this as a service for
Supabase databases. Copies are kept off-platform on your plan's schedule, every
copy is checked as it is taken, and a restore is a button.

## License

MIT
