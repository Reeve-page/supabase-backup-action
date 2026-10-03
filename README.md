# Supabase backup, with a restore check

> **Status: being built.** Nothing here backs anything up yet. The outline
> below is the plan, in the order it is being written.

A GitHub Action that dumps a Supabase database on a schedule, keeps the files
outside Supabase, and then restores them into a throwaway Postgres to prove
they work. A green workflow only proves the job exited zero. This one also
checks the file.

## What it will do

1. **Dump** roles, schema and data with the Supabase CLI, the way Supabase's
   backup and restore guide does, over the Session pooler.
2. **Keep** the files as a workflow artifact, or in any S3-compatible bucket
   (Cloudflare R2 included).
3. **Check** them: replay into a service-container Postgres, count the rows,
   and confirm your users came across, not just their table.

## Quick start

See [`examples/backup.yml`](examples/backup.yml). Put the Session pooler string
in a repository secret called `SUPABASE_DB_URL`, in a **private** repository.

## Inputs

See [`action.yml`](action.yml).

## What it does not back up

Files your users uploaded to Supabase Storage are not in a database dump, and
neither are Edge Function secrets or project settings.

## Writing behind it

- [Back up Supabase with a GitHub Action, free, plus the catch](https://reeve.page/blog/supabase-backup-github-action)
- [Test your Supabase backup: the 15-minute restore drill](https://reeve.page/blog/test-your-supabase-backup)
- [Your Supabase dump has everything except your users](https://reeve.page/blog/supabase-backup-auth-users)

If you would rather not run this yourself, [Reeve](https://reeve.page/supabase-backups)
does it as a service: verified copies kept off-platform, and a one-click restore.

## License

MIT
