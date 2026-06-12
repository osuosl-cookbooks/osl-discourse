#!/bin/bash
# Test helper (discourse_test). Runs the backup cron command, then checks the
# tarball is a real backup: filename convention + a non-empty SQL dump inside.
set -euo pipefail

container=forum
backup_dir="/var/discourse/shared/${container}/backups/default"

# Run the scheduled backup command, then grab the newest tarball it produced.
# Avoid `| head` so nothing upstream takes SIGPIPE under pipefail.
/usr/local/sbin/discourse-backup "$container"
listing=$(ls -t "$backup_dir"/*.tar.gz)
tarball=${listing%%$'\n'*}
[ -n "$tarball" ] || { echo "FAIL: no backup tarball in $backup_dir" >&2; exit 1; }
base=$(basename "$tarball")
echo "tarball: $base"

# Filename convention (restore rejects renamed files).
if [[ ! "$base" =~ -[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}-v[0-9]+\.tar\.gz$ ]]; then
  echo "FAIL: unexpected backup filename: $base" >&2
  exit 1
fi

# Archive must carry the gzipped SQL dump...
echo "--- archive contents ---"
tar tzf "$tarball"
dump=$(tar tzf "$tarball" | grep -E '(^|/)dump\.sql\.gz$' || true)
dump=${dump%%$'\n'*}
[ -n "$dump" ] || { echo "FAIL: dump.sql.gz missing from backup" >&2; exit 1; }

# ...and it must be a real dump. Read it fully (no grep -q/-m) so nothing
# upstream takes SIGPIPE under pipefail.
if ! tar xzOf "$tarball" "$dump" | zcat | grep -E 'CREATE TABLE|^COPY ' >/dev/null; then
  echo "FAIL: $dump contains no SQL schema/data" >&2
  exit 1
fi

echo "OK: $base is a valid Discourse backup (filename + SQL dump verified)"
