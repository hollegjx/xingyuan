#!/bin/sh
set -eu
umask 077

if [ "$#" -ne 3 ]; then
  printf '%s\n' 'Owner only: export-companion-backup.sh /private/ssh-config HOST_ALIAS /private/new-backup.tar.gz' >&2
  exit 64
fi
config=$1
host=$2
destination=$3
case "$config" in /*) ;; *) exit 64 ;; esac
case "$host" in ''|-*|*[!A-Za-z0-9_.-]*) exit 64 ;; esac
test -f "$config"
case "$destination" in /*) ;; *) exit 64 ;; esac
test ! -e "$destination"
test ! -L "$destination"
parent=$(dirname "$destination")
test -d "$parent"
temporary=$(mktemp -d "$parent/.xingyuan-export.XXXXXX")
trap 'rm -f "$temporary/backup.tar.gz"; rmdir "$temporary"' EXIT HUP INT TERM

ssh -F "$config" \
  -o BatchMode=yes -o PreferredAuthentications=publickey \
  -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
  -o StrictHostKeyChecking=yes -o ConnectionAttempts=1 \
  "$host" \
  'runuser -u xingyuan -- /opt/xingyuan/current/server/build/backup/bundle/bin/backup export --root /var/lib/xingyuan/backups' \
  > "$temporary/backup.tar.gz"

tar -tzf "$temporary/backup.tar.gz" > /dev/null
# Same-filesystem hard link refuses even an empty existing destination.
ln "$temporary/backup.tar.gz" "$destination"
printf 'Exported private backup: %s\n' "$destination"
