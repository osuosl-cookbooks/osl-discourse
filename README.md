# osl-discourse

Installs and manages [Discourse](https://www.discourse.org/) instances via the
upstream [discourse_docker](https://github.com/discourse/discourse_docker)
launcher. Designed for OSL hosts that point Discourse at the central PostgreSQL
cluster and sit behind the load balancer.

Rebuilds use a bootstrap-then-swap strategy that builds the new image while the
old container keeps serving, cutting per-rebuild downtime from ~15 minutes
(`launcher rebuild`) to roughly 30 seconds (`docker stop`/`docker run`). A weekly
cron drives the rebuild so security updates land on a predictable schedule.

## Requirements

### Platforms

- AlmaLinux 9+

### Cookbooks

- osl-docker
- osl-git

The consumer recipe is responsible for provisioning the PostgreSQL role,
database, and extensions (`hstore`, `pg_trgm`, `unaccent`, `vector`) on the
central PG cluster before declaring `osl_discourse`.

## Resources

### `osl_discourse`

Installs `discourse_docker`, renders the container yml, installs the
`discourse-rebuild` wrapper script, and schedules the weekly rebuild cron.

```ruby
osl_discourse 'forum.example.org' do
  container_name   'forum'
  db_host          'pg.example.org'
  db_user          'forum'
  db_password      'changeme'
  db_name          'forum'
  developer_emails 'admin@example.org'
  plugins %w(
    https://github.com/example/discourse-example-plugin.git
  )
  rebuild_mailto 'root@example.org'
end
```

#### Properties

| Property | Default | Notes |
| -------- | ------- | ----- |
| `hostname` | name | `DISCOURSE_HOSTNAME` |
| `container_name` | required | filename under `containers/` and docker container name |
| `launcher_dir` | `/var/discourse` | where `discourse_docker` is checked out |
| `shared_path_name` | `container_name` | subdir under `/var/discourse/shared/`; override only to preserve an existing data directory from a pre-`osl_discourse` install |
| `discourse_version` | `stable` | container `version` param (`stable`, `tests-passed`, or a SHA) |
| `db_host` / `db_port` / `db_user` / `db_password` / `db_name` | required (port 5432) | external PG; consumer recipe owns role/db/extensions |
| `db_backup_port` | `db_port` | only override if the backup target differs |
| `pg_client_version` | `16` | PG client version installed inside the container for `pg_dump` |
| `smtp_address` / `smtp_port` / `smtp_authentication` | `smtp.osuosl.org` / `587` / `none` | |
| `smtp_user_name` / `smtp_password` / `smtp_force_tls` / `smtp_domain` | unset | |
| `developer_emails` | required | comma-separated; initial admin signups |
| `unicorn_workers` | `4` | |
| `locale` / `notification_email` / `cdn_url` | unset | |
| `force_https` | `true` | Sets `DISCOURSE_FORCE_HTTPS=true` so Discourse generates `https://` URLs. Assumes the upstream proxy terminates TLS and sets `X-Forwarded-Proto: https`. Set to `false` for HTTP-only instances. |
| `plugins` | `[]` | Array of git URLs; `docker_manager` is always installed |
| `trusted_proxies` | OSL LB v4 + v6 addresses (lb1, lb2, vip-lb1) | rendered into `web.realip.template.yml` |
| `extra_env` / `extra_params` | `{}` | merged into the container yml |
| `extra_templates` | `[]` | additional pups template paths |
| `docker_args` | `--network host` | for local PG; remove for remote PG over the LAN |
| `skip_mac_address` | `true` | passed to launcher |
| `rebuild_day` / `rebuild_hour` / `rebuild_minute` | `Mon` / `11` / `10` | weekly window |
| `rebuild_time_zone` | `America/Los_Angeles` | handles DST automatically |
| `rebuild_mailto` | required | cron MAILTO |

#### Actions

- `:create` (default) — sync `discourse_docker`, render the container yml,
  install the rebuild script and cron; notifies `:rebuild` if the yml changed.
- `:rebuild` — run `/usr/local/sbin/discourse-rebuild <container>` now.

## Rebuild model

`/usr/local/sbin/discourse-rebuild` runs:

```text
./launcher bootstrap <config>   # builds new image, old container keeps serving
./launcher destroy   <config>   # stop + rm old container (≤ 30 s typical)
./launcher start     <config>   # start new container from the fresh image
```

A flock on `/var/discourse/cids/<config>.rebuild.lock` prevents concurrent
rebuilds (e.g. cron firing while an ops rebuild is in progress).

## Contributing

1. Fork the repository on GitHub
1. Create a named feature branch (like `username/add_component_x`)
1. Write tests for your change
1. Write your change
1. Run the tests, ensuring they all pass
1. Submit a pull request on GitHub

## License and Authors

- Author:: Oregon State University <chef@osuosl.org>

```text
Copyright:: 2026, Oregon State University

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```
