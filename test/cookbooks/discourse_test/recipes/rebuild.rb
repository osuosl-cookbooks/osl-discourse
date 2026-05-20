# Used by chefspec to exercise the osl_discourse :rebuild action in isolation
# (delayed notifications from action :create don't traverse step_into into a
# sibling action's body).
osl_discourse 'discourse.example.org' do
  container_name 'forum'
  db_host '127.0.0.1'
  db_user 'discourse'
  db_password 'discourse'
  db_name 'discourse'
  developer_emails 'admin@example.org'
  rebuild_mailto 'root@example.org'
  action :rebuild
end
