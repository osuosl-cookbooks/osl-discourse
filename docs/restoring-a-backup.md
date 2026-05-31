# Restoring / migrating from a web-GUI backup

How to bring up a Discourse instance from a `.tar.gz` backup downloaded from
another site's admin UI (`/admin/backups`), given the way this cookbook
deploys Discourse.

## What's different about this deployment

- Discourse runs in the upstream
  [discourse_docker](https://github.com/discourse/discourse_docker) container
  with `--network host`. Persistent data lives in
  `/var/discourse/shared/<shared_path>` on the host (mounted as `/shared`
  inside the container). `shared_path` defaults to `container_name`.
- **The database is external.** The container talks to the OSL central
  PostgreSQL cluster via `DISCOURSE_DB_*`, not a Postgres bundled in the
  container. `discourse restore` therefore loads into that external cluster.
  This is the only part of the standard restore flow that needs extra care
  (see [External database notes](#external-database-notes)).

A web-GUI backup is a `.tar.gz` containing a SQL dump plus — only if "include
uploads" was checked at download time — the uploaded files. Restoring only
loads database rows and uploads; it does **not** touch `containers.yml` or
anything Chef renders (hostname, SMTP, plugins, etc.).

## Before you restore

1. **Target version must be >= the source version.** Restore only refuses a
   backup taken on a *newer* Discourse than the target; restoring an *older*
   backup into a newer install is the supported direction — it loads the old
   schema and runs forward migrations up to the running version. So you do
   **not** need to pin `discourse_version` down to the source's version.
   Discourse staff's rule of thumb is that a backup less than ~5 years old
   should restore cleanly. For large gaps (a backup more than a year or two
   old), read [Restoring a very old backup](#restoring-a-very-old-backup)
   first — there are real caveats. Let Chef converge so the container is
   running before you start.

2. **Set site identity in the recipe, not via the backup.** Configure
   `hostname`, `developer_emails`, SMTP, and any `plugins` to match the source
   site *before* restoring, since the backup won't carry the container config.

3. **Confirm the external DB role can rebuild the schema.** The consumer recipe
   that owns `postgresql_role` / `postgresql_database` / `postgresql_extension`
   should have created the role as the database owner with the extensions
   (`hstore`, `pg_trgm`, `unaccent`, `vector`) already present. See
   [External database notes](#external-database-notes).

4. **Lock outgoing email OFF before you start.** A fresh boot or a restore can
   send password resets, digests, and activation mails to real users. Do this
   *first* — see [Preventing outgoing email during migration](#preventing-outgoing-email-during-migration).

## Preventing outgoing email during migration

This is the part to get right: you do **not** want Discourse mailing real users
while you migrate. There are two layers, and only one of them is sufficient.

### Why the restore's built-in disable isn't enough

After a restore, Discourse runs (in `lib/backup_restore/restorer.rb`):

```ruby
if @disable_emails && SiteSetting.disable_emails == "no"
  SiteSetting.set_and_log(:disable_emails, "non-staff", user)
end
```

That only sets **`non-staff`** (staff/admins *still* get mail) and only if the
value was `no` at restore time. Sidekiq is paused *during* the restore, but once
it unpauses, staff notifications can fire. So this is a safety net, not a
guarantee.

Worse, a restore **overwrites site settings with the backup's values** — so a
`disable_emails` you set in the admin UI or DB beforehand gets clobbered when
the backup loads.

### The reliable lever: force it via env (survives the restore)

Set `disable_emails` through an **environment variable**. Env-var overrides are
applied at every boot, **win over the DB value** (so the restore can't undo
them), and are locked read-only in the admin UI. This is the only layer that
holds across a restore.

In this cookbook, pass it through `extra_env` on the `osl_discourse` resource —
**with explicit quotes around `yes`**:

```ruby
osl_discourse 'discuss.openpower.foundation' do
  # ... existing properties ...
  extra_env('DISCOURSE_DISABLE_EMAILS' => '"yes"')
end
```

> ⚠️ The quotes are required. `extra_env` renders values **unquoted**, and YAML
> parses a bare `yes` as the boolean `true` — which is not a valid
> `disable_emails` value. Passing the Ruby string `'"yes"'` makes the rendered
> `containers.yml` line read `DISCOURSE_DISABLE_EMAILS: "yes"`, i.e. the string
> `yes`. (`non-staff` needs no quoting; only `yes`/`no` are YAML booleans.)

Converge (or `discourse-rebuild`), then **verify it took** before doing anything
else:

```bash
docker exec <container> rails runner 'puts SiteSetting.disable_emails'   # => yes
```

It should print `yes`, and in Admin → Settings the `disable emails` field shows
as overridden/read-only.

### Going live when the migration is done and verified

Remove the `extra_env('DISCOURSE_DISABLE_EMAILS' => '"yes"')` line from the
recipe and converge (or `discourse-rebuild <container>`). With the env override
gone, `disable_emails` falls back to the DB value; set it to `no` in
Admin → Settings → Email if it isn't already. Send a test email from
Admin → Email to confirm delivery works before announcing the site.

> A `rails runner 'SiteSetting.disable_emails = "yes"'` (DB-side) toggle works
> too, but **only use it post-restore** — anything you set before a restore is
> overwritten by the backup. The env approach above avoids that race entirely,
> which is why it's preferred.

## Restoring a very old backup

Restoring a backup from a much older Discourse (e.g. **2.8.x**, early 2022)
into a current 3.x install is *allowed* by the version check and Discourse runs
forward migrations to bridge the gap. It's within the supported window
(< ~5 years), but a multi-year jump carries two distinct risks — pick the path
that fits whether the source site still exists.

**Risk 1 — migration gap.** The dump is the old schema; restore runs every
migration from then to now in one shot. Across several major releases this is
where restores most often fail.

**Risk 2 (cookbook-specific) — you can't easily bootstrap the old app here.**
The "just pin `discourse_version` to 2.8.3 and restore there" trick is harder
than it sounds in this cookbook, because the resource checks out the launcher
at `main` and defaults `pg_client_version 16`. A 2.8.x-era *app* expects an
older base image (older Ruby) and PostgreSQL **13**, so bootstrapping it inside
today's image is fragile and may not build at all. Pinning the app version
alone isn't enough — you'd also have to pin the launcher checkout and
`pg_client_version`, which is fiddly and unsupported.

**Preferred path — upgrade the source first.** If the old 2.8.3 site is still
running or recoverable, upgrade *it* through its normal upgrade path to a
recent release, take a **fresh backup**, and restore that. A
current-version-to-current-version restore avoids both risks above entirely and
is the clean, well-trodden route. This is the recommended approach whenever the
source is still accessible.

**If you only have the old `.tar.gz`:** restore it straight into the current
deployment and let forward migrations run. 2.8.3 → current is inside the
supported window, so it will likely work — but **test it first** in a
kitchen/staging converge with a copy of the backup, not against production.
Watch the restore log for migration failures. If it fails partway, the restore
moved your previous data to a `backup` schema (see
[External database notes](#external-database-notes)) so the live DB isn't lost;
investigate the failing migration before retrying.

## Manual restore (one-off migration)

1. **Drop the backup on the host** in the shared backups directory. Replace
   `<shared_path>` with your value (defaults to `container_name`):

   ```bash
   mkdir -p /var/discourse/shared/<shared_path>/backups/default
   cp your-backup.tar.gz /var/discourse/shared/<shared_path>/backups/default/
   ```

   The backup **filename must be left unchanged**, including the version
   string (e.g. `forum-backup-2020-08-25-130416-v20200820232017.tar.gz`) —
   Discourse treats the filename as metadata and restore fails if it's
   altered. Files downloaded from the GUI already follow this convention.
   A root-owned, world-readable file (what `scp`/`cp`/Chef's `remote_file`
   produce) is fine; the restore process only needs to read it. Once in place
   the backup also appears under `/admin/backups` in the web UI.

2. **Restore via the `discourse` CLI** (either `docker exec <container> ...` or
   `cd /var/discourse && ./launcher enter <container>`):

   ```bash
   docker exec <container> discourse enable_restore
   docker exec <container> discourse restore your-backup.tar.gz
   docker exec <container> discourse disable_restore
   ```

3. **Remap the hostname if the domain changed**, then rebake:

   ```bash
   docker exec <container> discourse remap old.hostname new.hostname
   /usr/local/sbin/discourse-rebuild <container>
   ```

   Skip the remap if the domain is unchanged. The rebuild (or the next weekly
   rebuild cron) rebakes posts; you can also run
   `docker exec <container> discourse rebake` directly.

4. **Leave email locked off until you're done**, then re-enable. The restore
   only sets `disable_emails` to `non-staff` (staff still get mail), so during a
   migration you should have email hard-locked via the env override described in
   [Preventing outgoing email during migration](#preventing-outgoing-email-during-migration).
   Re-enable only after verifying the site — see
   [Going live](#going-live-when-the-migration-is-done-and-verified).

## External database notes

The restore runs against the external OSL PG cluster (not a Postgres bundled in
the container), so it's worth knowing exactly what it does to the database and
what privileges the `db_user` role needs.

### What restore actually does to the DB

From Discourse's `lib/backup_restore/database_restorer.rb` and the
`BackupRestore.move_tables_between_schemas` helper, the restore does **not**
drop and recreate the `public` schema. In order it:

1. `CREATE SCHEMA IF NOT EXISTS backup`, then moves every existing table, view,
   materialized view, and enum out of `public` into a `backup` schema via
   `ALTER … SET SCHEMA backup` (this is the rollback safety net; the `backup`
   schema is dropped automatically after 7 days).
2. Pipes the dump through `psql --single-transaction --variable=ON_ERROR_STOP=1`,
   recreating the tables in `public`. The dump is `sed`-filtered first to strip
   `CREATE SCHEMA`, `DROP SCHEMA`, `COMMENT ON SCHEMA`, **and `CREATE EXTENSION` /
   `COMMENT ON EXTENSION`** — so extensions are expected to *already exist* in
   the target database; they are not created by the restore.
3. Creates readonly shim functions in a `discourse_functions` schema, then runs
   `rake db:migrate`.

### Privilege requirements

Superuser is **not** required ([confirmed on
meta](https://meta.discourse.org/t/cant-restore-to-external-db/137696)). The
`db_user` role needs to be able to:

- **Create schemas** in the database (for `backup` and `discourse_functions`) —
  i.e. `CREATE` on the database.
- **Own the existing objects** in `public`, since `ALTER … SET SCHEMA` requires
  ownership. A role that owns the database and created all current objects has
  this.
- **Create functions** (for the `discourse_functions` shims).

Because `CREATE EXTENSION` is stripped from the dump, the four extensions
(`hstore`, `pg_trgm`, `unaccent`, `vector`) **must** already be present in the
database or the restore fails on dependent objects. If restore errors on
permissions, confirm the role owns the database and that all four extensions
exist before reaching for any temporary privilege grant.

### OSL central cluster setup (osl-postgresql databags)

On the OSL cluster the role, database, and extensions are **not** provisioned by
this cookbook or the Discourse consumer recipe — they're declared in the
`postgres` data bag that `osl_postgresql_server` reads on the PG nodes
(`pg1`/`pg2`/`pg3`, configured in `osl-nodes::pg`). The privilege posture above
maps onto three things, all of which the OPF forum already has:

1. **Database owned by the Discourse role** — in `data_bags/postgres/databases.json`:

   ```json
   { "name": "opf_forum", "resource": "postgresql_database",
     "attributes": { "owner": "opf_forum" } }
   ```

   The `owner` is what gives the role `CREATE` on the database plus ownership of
   its objects — everything restore needs to move tables into the `backup`
   schema and recreate them. No `superuser`/`createdb` is required.

2. **The four extensions created in that database** — also in `databases.json`,
   one entry each, pointing at the DB via `dbname`:

   ```json
   { "name": "hstore",   "resource": "postgresql_extension", "attributes": { "dbname": "opf_forum" } },
   { "name": "pg_trgm",  "resource": "postgresql_extension", "attributes": { "dbname": "opf_forum" } },
   { "name": "unaccent", "resource": "postgresql_extension", "attributes": { "dbname": "opf_forum" } },
   { "name": "vector",   "resource": "postgresql_extension", "attributes": { "dbname": "opf_forum" } }
   ```

3. **The `vector` package installed cluster-wide** — `vector` (pgvector) needs a
   package for its `.so`; the contrib extensions don't. This is handled by the
   `extensions` property on `osl_postgresql_server` in `osl-nodes::pg`
   (`extensions %w(postgis vector)`), which installs the package on every node
   so a promoted standby can load it. Creating the extension on the database is
   separate (step 2).

The Discourse **role** lives in the encrypted `data_bags/postgres/users.json`
and only needs `login: true` (plus a password matching the site's credentials
databag, e.g. `opf/forum`). Do **not** grant it `superuser`, `createrole`, or
`createdb` — none are needed for restore and they're undesirable on the shared
cluster.

For a **new** Discourse site, replicate the same shape: add a
`postgresql_database` owned by the new role plus the four `postgresql_extension`
entries to `databases.json`, and add the role to `users.json`. The `vector`
package is already cluster-wide, so `osl-nodes::pg` needs no change.

### Which connection restore uses

`BackupRestore.database_configuration` reads the live ActiveRecord config
(populated from the container's `DISCOURSE_DB_*` env vars), using the normal
`username`/`password`/`database`. Notably it honors **`backup_host` / `backup_port`,
falling back to `host` / `port`** — which is why this cookbook exposes
`db_backup_port` (rendered as `DISCOURSE_DB_BACKUP_PORT`). If your cluster
routes writes to a primary on a different port than reads, set `db_backup_port`
so restore connects to the writable node. The restore never edits
`DISCOURSE_DB_*` itself — it loads into whatever DB the running container points
at.
