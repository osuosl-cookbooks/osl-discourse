osl_postgresql_test 'discourse' do
  username 'discourse'
  password 'discourse'
  # pgvector lives in PGDG, not AlmaLinux appstream; :repo also lets
  # osl_postgresql_test install the pgvector package for the vector extension.
  source :repo
  extensions %w(hstore pg_trgm unaccent vector)
end

osl_discourse 'discourse.example.org' do
  container_name 'forum'
  db_host node['ipaddress']
  db_user 'discourse'
  db_password 'discourse'
  db_name 'discourse'
  developer_emails 'admin@example.org'
  rebuild_mailto 'root@example.org'
end

# Backup verifier the inspec suite invokes during verify (test-only).
cookbook_file '/opt/verify-discourse-backup' do
  source 'verify-backup.sh'
  mode '0755'
end
