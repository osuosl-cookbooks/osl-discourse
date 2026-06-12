# Exercises backup_enabled false: the backup cron should be removed rather than
# created.
osl_discourse 'discourse.example.org' do
  container_name 'forum'
  db_host '127.0.0.1'
  db_user 'discourse'
  db_password 'discourse'
  db_name 'discourse'
  developer_emails 'admin@example.org'
  rebuild_mailto 'root@example.org'
  backup_enabled false
end
