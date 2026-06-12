# Shared by the `default` (port 80) and `listen-port` (8080) kitchen suites.
# The listen_port input drives both the expectations on the rendered
# containers.yml and the host port the container is verified to serve on.
listen_port = input('listen_port', value: 80)
base_url = listen_port.to_i == 80 ? 'http://localhost' : "http://localhost:#{listen_port}"

control 'default' do
  describe directory '/var/discourse' do
    it { should exist }
  end

  describe file '/var/discourse/launcher' do
    it { should exist }
    it { should be_executable }
  end

  describe file '/var/discourse/containers/forum.yml' do
    it { should exist }
    its('mode') { should cmp '0640' }
    its('content') { should match(/^  DISCOURSE_HOSTNAME: discourse\.example\.org$/) }
    its('content') { should match(/^  DISCOURSE_DEVELOPER_EMAILS: 'admin@example\.org'$/) }
    its('content') { should match(/^  DISCOURSE_DB_USERNAME: discourse$/) }
    its('content') { should match(/^  DISCOURSE_DB_NAME: discourse$/) }
    its('content') { should match(%r{git clone https://github\.com/discourse/docker_manager\.git}) }
    its('content') { should match(/apt-get install -y postgresql-16/) }
    its('content') { should match(/^  DISCOURSE_FORCE_HTTPS: true$/) }
    its('content') { should match(/^  DISCOURSE_MAXIMUM_BACKUPS: 3$/) }
    if listen_port.to_i == 80
      its('content') { should_not match(/after_web_config/) }
    else
      its('content') { should match(/^  after_web_config:$/) }
      its('content') { should match(/to: "listen #{listen_port};"/) }
      its('content') { should match(/to: "listen \[::\]:#{listen_port};"/) }
    end
  end

  describe file '/var/discourse/templates/web.realip.template.yml' do
    it { should exist }
    its('content') { should match(/set_real_ip_from 140\.211\.9\.50;/) }
    its('content') { should match(/set_real_ip_from 140\.211\.9\.52;/) }
    its('content') { should match(/set_real_ip_from 140\.211\.9\.53;/) }
    its('content') { should match(/set_real_ip_from 2605:bc80:3010:104::8cd3:932;/) }
    its('content') { should match(/set_real_ip_from 2605:bc80:3010:104::8cd3:934;/) }
    its('content') { should match(/set_real_ip_from 2605:bc80:3010:104::8cd3:935;/) }
  end

  describe file '/usr/local/sbin/discourse-rebuild' do
    it { should exist }
    its('mode') { should cmp '0750' }
    its('content') { should match(%r{^./launcher bootstrap "\$config" "\$@" 2>&1 \| redact$}) }
    its('content') { should match(%r{^./launcher destroy   "\$config" *2>&1 \| redact$}) }
    its('content') { should match(%r{^./launcher start     "\$config" "\$@" *2>&1 \| redact$}) }
    its('content') { should match(/flock -n 9/) }
    its('content') { should match(/_PASSWORD\|_KEY\|_SECRET\|_TOKEN/) }
  end

  describe file '/usr/local/sbin/discourse-backup' do
    it { should exist }
    its('mode') { should cmp '0750' }
    its('content') { should match(/flock -w 1200 9/) }
    its('content') { should match(/^exec docker exec "\$config" discourse backup$/) }
  end

  # Mon 11:10 PT is written in UTC; either 18:10 (PDT) or 19:10 (PST) depending
  # on when the integration test runs.
  describe file '/etc/cron.d/discourse-rebuild-forum' do
    it { should exist }
    its('content') { should match(/^MAILTO=root@example\.org$/) }
    its('content') do
      should match(%r{^10 (18|19) \* \* (Mon|mon) root /usr/local/sbin/discourse-rebuild forum --docker-args "--network host" --skip-mac-address$})
    end
  end

  # Daily at 02:00 UTC (ahead of the 05:00-13:00 UTC rdiff pull window), weekday '*'.
  describe file '/etc/cron.d/discourse-backup-forum' do
    it { should exist }
    its('content') { should match(/^MAILTO=root@example\.org$/) }
    its('content') do
      should match(%r{^0 2 \* \* \* root /usr/local/sbin/discourse-backup forum$})
    end
  end

  describe service 'postgresql-16' do
    it { should be_running }
  end

  describe service 'disable-transparent-hugepages' do
    it { should be_enabled }
  end

  describe file '/sys/kernel/mm/transparent_hugepage/enabled' do
    its('content') { should match(/\[never\]/) }
  end

  describe docker_container 'forum' do
    it { should exist }
    it { should be_running }
    its('image') { should match(%r{^local_discourse/forum}) }
  end

  describe port listen_port.to_i do
    it { should be_listening }
  end

  # Discourse needs a few seconds after `launcher start` returns before Unicorn
  # is warm enough to serve traffic; the rest of the HTTP checks below depend
  # on this curl succeeding first. --retry-connrefused covers the "container is
  # up, Unicorn not bound yet" window; --retry covers transient 5xx during boot.
  describe command "curl --retry 60 --retry-delay 2 --retry-connrefused --max-time 5 -sS -o /dev/null -w \"%{http_code}\" -H \"Host: discourse.example.org\" #{base_url}/srv/status" do
    its('exit_status') { should eq 0 }
    its('stdout') { should cmp '200' }
  end

  # /srv/status is Discourse's intentional lightweight health endpoint;
  # returns plain "ok" with 200 once the site is responsive.
  describe http(
    "#{base_url}/srv/status",
    headers: { 'Host' => 'discourse.example.org' }
  ) do
    its('status') { should cmp 200 }
    its('body') { should match(/ok/) }
  end

  # Bare GET / should serve the Discourse app (200 once bootstrapped, 302 to
  # /wizard on a brand-new install before the admin completes setup).
  describe http(
    "#{base_url}/",
    headers: { 'Host' => 'discourse.example.org' }
  ) do
    its('status') { should be_in [200, 302] }
  end

  # End-to-end: run the backup cron command and confirm the tarball is a real
  # backup. Independent of listen_port, so only run it in the default suite.
  if listen_port.to_i == 80
    describe command('/opt/verify-discourse-backup') do
      its('exit_status') { should eq 0 }
      its('stdout') { should match(/is a valid Discourse backup/) }
    end
  end
end
