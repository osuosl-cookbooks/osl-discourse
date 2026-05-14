require_relative '../../spec_helper'

describe 'discourse_test::default' do
  platform 'almalinux'
  cached(:subject) { chef_run }
  step_into :osl_discourse

  before do
    stub_command('iptables -C INPUT -j REJECT --reject-with icmp-host-prohibited 2>/dev/null').and_return(true)
    # Pin "today" to a Monday during PDT so the UTC conversion is deterministic.
    allow(Date).to receive(:today).and_return(Date.new(2026, 7, 6))
  end

  it { is_expected.to include_recipe 'osl-docker' }
  it { is_expected.to include_recipe 'osl-git' }

  it { is_expected.to create_systemd_unit('disable-transparent-hugepages.service') }
  it { is_expected.to enable_systemd_unit('disable-transparent-hugepages.service') }
  it { is_expected.to start_systemd_unit('disable-transparent-hugepages.service') }
  it do
    expect(chef_run.systemd_unit('disable-transparent-hugepages.service').content).to \
      match(%r{ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'})
  end

  it { is_expected.to create_directory('/var/discourse') }

  it do
    is_expected.to sync_git('/var/discourse').with(
      repository: 'https://github.com/discourse/discourse_docker.git',
      revision: 'main',
      ignore_failure: true
    )
  end

  it do
    is_expected.to create_cookbook_file('/usr/local/sbin/discourse-rebuild').with(
      source: 'discourse-rebuild',
      cookbook: 'osl-discourse',
      mode: '0750',
      owner: 'root',
      group: 'root'
    )
  end

  it do
    is_expected.to create_template('/var/discourse/templates/web.realip.template.yml').with(
      source: 'web.realip.template.yml.erb',
      cookbook: 'osl-discourse'
    )
  end

  it do
    expect(chef_run.template('/var/discourse/templates/web.realip.template.yml')).to \
      notify('osl_discourse[discourse.example.org]').to(:rebuild).delayed
  end

  it do
    is_expected.to create_template('/var/discourse/containers/forum.yml').with(
      source: 'containers.yml.erb',
      cookbook: 'osl-discourse',
      mode: '0640',
      sensitive: true
    )
  end

  it do
    expect(chef_run.template('/var/discourse/containers/forum.yml')).to \
      notify('osl_discourse[discourse.example.org]').to(:rebuild).delayed
  end

  # Mon 11:10 PDT (UTC-7) → Mon 18:10 UTC.
  it do
    is_expected.to create_cron_d('discourse-rebuild-forum').with(
      command: '/usr/local/sbin/discourse-rebuild forum --docker-args "--network host" --skip-mac-address',
      weekday: 'Mon',
      hour: 18,
      minute: 10,
      mailto: 'root@example.org'
    )
  end
end
