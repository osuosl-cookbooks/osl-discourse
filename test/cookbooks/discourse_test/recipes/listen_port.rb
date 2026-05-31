# Full converge with a non-default nginx listen_port (8080). Mirrors the
# default recipe but proves the after_web_config rewrite hook makes the
# host-networked container actually bind 8080 instead of 80. Also exercised by
# chefspec, which asserts the hook renders in containers.yml.
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
  listen_port 8080
  db_host node['ipaddress']
  db_user 'discourse'
  db_password 'discourse'
  db_name 'discourse'
  developer_emails 'admin@example.org'
  rebuild_mailto 'root@example.org'
end
