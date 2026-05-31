provides :osl_discourse
unified_mode true

default_action :create

# Identity
property :hostname,          String, name_property: true
property :container_name,    String, required: true
property :launcher_dir,      String, default: '/var/discourse'
property :shared_path_name,  String
property :discourse_version, String, default: 'stable'

# Database (external; consumer recipe provisions role/db/extensions)
property :db_host,                       String, required: true
property :db_port,                       [String, Integer], default: 5432
property :db_backup_port,                [String, Integer]
property :db_user,                       String, required: true
property :db_password,                   String, sensitive: true, required: true
property :db_name,                       String, required: true
property :db_default_text_search_config, String, default: 'pg_catalog.english'
property :pg_client_version,             Integer, default: 16

# SMTP
property :smtp_address,        String, default: 'smtp.osuosl.org'
property :smtp_port,           [String, Integer], default: 587
property :smtp_authentication, String, default: 'none'
property :smtp_user_name,      String, sensitive: true
property :smtp_password,       String, sensitive: true
property :smtp_force_tls,      [true, false], default: false
property :smtp_domain,         String

# Discourse runtime
property :developer_emails,    String, required: true
property :unicorn_workers,     Integer, default: 4
property :locale,              String
property :notification_email,  String
property :cdn_url,             String
# OSL Discourse instances sit behind an HTTPS-terminating HAProxy by default.
# DISCOURSE_FORCE_HTTPS makes Discourse generate https:// URLs in emails,
# OAuth callbacks, oembeds, etc. Requires the proxy to set
# X-Forwarded-Proto: https on forwarded requests.
property :force_https,         [true, false], default: true

# Plugins (docker_manager is always installed; do not list it here)
property :plugins, Array, default: []

# Reverse-proxy real IP (OSL load balancers)
property :trusted_proxies, Array, default: %w(
  140.211.9.50
  140.211.9.52
  140.211.9.53
  2605:bc80:3010:104::8cd3:932
  2605:bc80:3010:104::8cd3:934
  2605:bc80:3010:104::8cd3:935
)

# Extensibility
property :extra_env,       Hash,  default: {}
property :extra_params,    Hash,  default: {}
property :extra_templates, Array, default: []

# Launcher invocation
property :docker_args,       String,        default: '--network host'
property :skip_mac_address,  [true, false], default: true
# nginx listen port inside the host-networked container. Defaults to 80; set
# higher when another service on the host owns 80. The container runs with
# --network host, so the bundled nginx binds this port directly on the host.
property :listen_port,       [String, Integer], default: 80

# Weekly bootstrap-then-swap rebuild
property :rebuild_day,       String, default: 'Mon'
property :rebuild_hour,      String, default: '11'
property :rebuild_minute,    String, default: '10'
property :rebuild_time_zone, String, default: 'America/Los_Angeles'
property :rebuild_mailto,    String, required: true

action :create do
  include_recipe 'osl-docker'
  include_recipe 'osl-git'

  # Redis (bundled in the Discourse container) requires THP disabled on the host.
  # Apply at boot before docker.service so the container never sees THP enabled.
  systemd_unit 'disable-transparent-hugepages.service' do
    content <<~UNIT
      [Unit]
      Description=Disable Transparent Huge Pages (required by Discourse's bundled Redis)
      DefaultDependencies=no
      After=sysinit.target local-fs.target
      Before=docker.service

      [Service]
      Type=oneshot
      ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
      RemainAfterExit=yes

      [Install]
      WantedBy=basic.target
    UNIT
    action [:create, :enable, :start]
  end

  directory new_resource.launcher_dir

  git new_resource.launcher_dir do
    repository 'https://github.com/discourse/discourse_docker.git'
    revision 'main'
    ignore_failure true
  end

  cookbook_file discourse_rebuild_script do
    source 'discourse-rebuild'
    cookbook 'osl-discourse'
    mode '0750'
    owner 'root'
    group 'root'
  end

  realip = template discourse_realip_template(new_resource.launcher_dir) do
    source 'web.realip.template.yml.erb'
    cookbook 'osl-discourse'
    mode '0644'
    variables(trusted_proxies: new_resource.trusted_proxies)
    not_if { new_resource.trusted_proxies.empty? }
  end

  container_yml = template discourse_container_yml(new_resource.launcher_dir, new_resource.container_name) do
    source 'containers.yml.erb'
    cookbook 'osl-discourse'
    mode '0640'
    sensitive true
    variables(
      hostname: new_resource.hostname,
      container_name: new_resource.container_name,
      listen_port: new_resource.listen_port,
      shared_path: discourse_shared_path(new_resource.container_name, new_resource.shared_path_name),
      discourse_version: new_resource.discourse_version,
      unicorn_workers: new_resource.unicorn_workers,
      locale: new_resource.locale,
      notification_email: new_resource.notification_email,
      cdn_url: new_resource.cdn_url,
      force_https: new_resource.force_https,
      developer_emails: new_resource.developer_emails,
      smtp_address: new_resource.smtp_address,
      smtp_port: new_resource.smtp_port,
      smtp_authentication: new_resource.smtp_authentication,
      smtp_user_name: new_resource.smtp_user_name,
      smtp_password: new_resource.smtp_password,
      smtp_force_tls: new_resource.smtp_force_tls,
      smtp_domain: new_resource.smtp_domain,
      db_host: new_resource.db_host,
      db_port: new_resource.db_port,
      db_backup_port: new_resource.db_backup_port || new_resource.db_port,
      db_user: new_resource.db_user,
      db_password: new_resource.db_password,
      db_name: new_resource.db_name,
      db_default_text_search_config: new_resource.db_default_text_search_config,
      pg_client_version: new_resource.pg_client_version,
      trusted_proxies: new_resource.trusted_proxies,
      plugins: new_resource.plugins,
      extra_env: new_resource.extra_env,
      extra_params: new_resource.extra_params,
      extra_templates: new_resource.extra_templates
    )
  end

  # Run the rebuild during :create rather than via :delayed notifies so the
  # container is up before any subsequent recipe in the run list. Fires when
  # either template just changed, or the container doesn't exist yet
  # (first-time install). With unified_mode, both template resources above
  # have already executed by the time this only_if is evaluated.
  execute "rebuild Discourse: #{new_resource.container_name}" do
    command discourse_rebuild_command(new_resource.container_name, new_resource.docker_args, new_resource.skip_mac_address)
    live_stream true
    only_if do
      realip.updated_by_last_action? ||
        container_yml.updated_by_last_action? ||
        !discourse_container_exists?(new_resource.container_name)
    end
  end

  # OSL hosts run in UTC; convert the operator-friendly schedule to UTC at
  # converge time. The Supermarket `cron` cookbook (pulled in transitively
  # via base → chef-client → cron) shadows Chef-core's cron_d, so its
  # `time_zone` property isn't available — we handle DST in Ruby instead.
  # The cron entry stays correct until the next DST boundary; subsequent
  # chef-client converges recompute and update it.
  utc_schedule = discourse_cron_utc(
    new_resource.rebuild_day,
    new_resource.rebuild_hour,
    new_resource.rebuild_minute,
    new_resource.rebuild_time_zone
  )

  cron_d "discourse-rebuild-#{new_resource.container_name}" do
    command discourse_rebuild_command(new_resource.container_name, new_resource.docker_args, new_resource.skip_mac_address)
    weekday utc_schedule[:weekday]
    hour    utc_schedule[:hour]
    minute  utc_schedule[:minute]
    mailto  new_resource.rebuild_mailto
  end
end

action :rebuild do
  execute "discourse-rebuild #{new_resource.container_name}" do
    command discourse_rebuild_command(new_resource.container_name, new_resource.docker_args, new_resource.skip_mac_address)
    live_stream true
  end
end
