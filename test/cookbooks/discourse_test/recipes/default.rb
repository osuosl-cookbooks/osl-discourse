osl_postgresql_test 'discourse' do
  username 'discourse'
  password 'discourse'
  # PGDG repo is required for pgvector_16; the default :os source pulls from
  # AlmaLinux appstream which doesn't ship pgvector.
  source :repo
  extensions %w(hstore pg_trgm unaccent)
end

# pgvector_16 depends on postgresql16-server, so it must install after the
# server is in place; the `vector` extension must then be created after the
# package is installed (mirrors the proj-snowdrift::forum wrapper).
package 'pgvector_16'

postgresql_extension 'vector' do
  dbname 'discourse'
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
