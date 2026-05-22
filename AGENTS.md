# AGENTS.md

Context for AI assistants working in this cookbook.

## What this cookbook does

Manages [Discourse](https://www.discourse.org/) instances via the upstream
[discourse_docker](https://github.com/discourse/discourse_docker) launcher.
The `osl_discourse` custom resource is the entire public surface area; the
default recipe is intentionally a no-op. Designed to be called from a wrapper
recipe in another cookbook that owns the PG side (role, database, extensions)
and any site-specific firewall/proxy setup.

## Toolchain

- **Cookstyle:** `cinc exec cookstyle` (not raw `cookstyle`). Use `-a` to auto-fix.
- **Chefspec:** `cinc exec rspec spec/` from the cookbook root.
- **Kitchen:** `kitchen.yml` uses the **`cinc_infra`** provisioner — do not
  "modernize" to `chef_infra` with `product_name: cinc`. That's the org
  convention.
- **Dependencies** are resolved via Berkshelf. The test cookbook
  (`test/cookbooks/discourse_test`) is pulled in via a `cookbook ... path:`
  line in the `Berksfile`. Production deps are declared in `metadata.rb`
  (`osl-docker`, `osl-git`). **Do not add `depends 'cron'`** even though
  this cookbook calls `cron_d` — the Supermarket `cron` cookbook is already
  pulled in transitively (`base` → `chef-client` → `cron`) and the org
  pattern is to rely on that, matching `osl-apache`, `osl-backup`, etc.

## Resource design notes

- **External DB only.** The resource does not provision PostgreSQL. Production
  callers hit the OSL central PG cluster; the consumer recipe owns
  `postgresql_role` / `postgresql_database` / `postgresql_extension`. The test
  cookbook uses `osl_postgresql_test` (with `source :repo` so pgvector is
  available) to stand up a local instance.
- **Plugins** is an Array of git URLs. `docker_manager` is always installed
  (don't list it in `plugins`); it's required for the web-UI upgrade flow.
- **`shared_path_name`** defaults to `container_name`. Only override it when
  adopting a pre-existing `/var/discourse/shared/<old_name>` data directory
  on a host that ran Discourse before `osl_discourse` managed it — pointing
  at the wrong path loses uploads, backups, and the local Redis/PG snapshots.
- **`trusted_proxies`** defaults to the OSL LB IPs (v4 + v6) and renders
  `web.realip.template.yml`. Set to `[]` for instances not behind a proxy.
- **THP is disabled via `systemd_unit`**, not a one-shot `execute`. Redis
  (bundled in the Discourse container) requires THP off, and a plain `execute`
  doesn't survive reboots — so the unit ships with `Before=docker.service` and
  runs at every boot. Don't "simplify" it back to an `execute`.
- **Helpers live in `libraries/helpers.rb`**, not in an `action_class do`
  block, matching `osl-postgresql` / `osl-gpu` / other osl-* cookbooks. Helpers
  take primitives as arguments (not `new_resource`) and are included into
  `Chef::DSL::Recipe` and `Chef::Resource` at the bottom of the file.
- **Rebuild runs inline during `:create`, not via notifies.** Templates are
  assigned to local variables (`realip = template ... do ... end` and
  `container_yml = template ... do ... end`), and the rebuild `execute` is
  declared last with an `only_if` that checks
  `realip.updated_by_last_action? || container_yml.updated_by_last_action? ||
  !discourse_container_exists?(container_name)`. With `unified_mode`, both
  templates have already run by the time the only_if is evaluated. This
  shape was picked after two prior failures:
  - `:immediately` notifies fired after the *first* template rendered, so
    the launcher errored with `containers/<name>.yml does not exist or is
    not readable` because the second template hadn't run yet.
  - `:delayed` notifies deferred the rebuild to end-of-converge, leaving
    subsequent recipes in the same run list (e.g. snowdrift's
    `docker exec snowdrift-forum discourse enable_restore`) executing
    against a container that didn't exist yet.
- **`discourse_container_exists?` uses docker-api**, not a shell-out to
  `docker ps`. The gem is loaded transitively via osl-docker. The helper
  swallows `Docker::Error::NotFoundError`, generic `StandardError` (daemon
  down), and `LoadError` (gem missing) — all return false so the only_if
  fires the rebuild and lets it fail loudly if docker really isn't usable.

## Scheduling: UTC conversion at converge time

The weekly rebuild uses `cron_d`, but **not** with its `time_zone` property.
The Supermarket [`cron` cookbook](https://supermarket.chef.io/cookbooks/cron)
is pulled in transitively across the org (every cookbook → `base` →
`chef-client` → `cron`) and its custom `cron_d` resource shadows Chef-core's,
without supporting `time_zone`. Setting `time_zone` raises
`NoMethodError: undefined method 'time_zone' for Custom resource cron_d from
cookbook cron` at converge time.

Workaround: the `discourse_cron_utc` helper in `libraries/helpers.rb` converts
the operator-friendly `(weekday, hour, minute, tz)` into a UTC
`{ minute:, hour:, weekday: }` triple at converge time, and `cron_d` is given
those UTC values directly. OSL hosts run on UTC by default, so cron fires at
the intended local-wall-clock time. DST boundaries shift the conversion; the
next chef-client converge recomputes and updates the cron entry.

Implementation note: the helper uses Ruby stdlib (`Time.local` + `ENV['TZ']`
backed by system tzdata in `/usr/share/zoneinfo/`) rather than the `tzinfo`
gem, because **Cinc Client does not ship `tzinfo`** — `require 'tzinfo'` at
the top of a library file fails at compile time on the converge target. Local
chefspec/workstation has `tzinfo` so this isn't caught by unit tests alone.

If/when the Supermarket `cron` cookbook is dropped or modernized across the
org, `cron_d` can be called with `time_zone` directly and the helper retired.

## Rebuild model

`/usr/local/sbin/discourse-rebuild` is a thin bash wrapper around the
launcher's `bootstrap`/`destroy`/`start` primitives — **not** `launcher
rebuild`. The point is to build the new image while the old container keeps
serving (~15 min, zero downtime), then do a quick stop/start swap (~30 s).
`launcher rebuild` stops first then bootstraps, producing the full 15 min
outage we're trying to avoid.

The script uses `flock -n 9` on `/var/discourse/cids/<config>.rebuild.lock`
so a cron-triggered rebuild can't collide with an ops-triggered one. `set
-euo pipefail` ensures a failed bootstrap aborts before we touch the live
container.

The launcher's `set -x` around `docker run` echoes every `-e VAR=value`
flag, which would dump `DISCOURSE_DB_PASSWORD` and similar to the chef
log under `live_stream true`. The wrapper pipes all launcher output
through a sed redactor that masks `-e NAME=value` where NAME ends in
`_PASSWORD`, `_KEY`, `_SECRET`, or `_TOKEN`. New secret-shaped env vars
added via `extra_env` get redacted automatically if they follow that
naming convention; anything outside it would land in the log verbatim.

The resource exposes the rebuild three ways:

- `action :create` (default) runs the rebuild inline when needed (see
  Resource design notes above).
- `action :rebuild` (manual trigger). Useful from a recipe via
  `osl_discourse 'foo' do; action :rebuild; end` or as a notify target.
  Streams output live (`live_stream true`).
- The weekly `cron_d` writes `/etc/cron.d/discourse-rebuild-<container>`
  invoking `/usr/local/sbin/discourse-rebuild` directly.

## Versioning and CHANGELOG

Do not bump `metadata.rb`'s `version` manually, and do not add `CHANGELOG.md`
entries. The OSL Jenkins pipeline owns both — version bumps land as commits
like `Automatic patch-level version bump to vX.Y.Z by Jenkins`, and the
CHANGELOG is generated from PR titles/descriptions. Manual edits to either
file create merge friction with the auto-bump commit.

Existing CHANGELOG content is fine to keep; just don't *add* new entries
yourself.

## Quick checks before opening a PR

```bash
cd /data/git/osl/chef-repo/osuosl-cookbooks/osl-discourse
cinc exec cookstyle
cinc exec rspec spec/
```

Integration (`kitchen test`) does a real Discourse bootstrap, which pulls a
multi-GB image and takes ~15 min. Skip it for documentation-only PRs; run it
when changing the resource, the rebuild wrapper, or the container template.
