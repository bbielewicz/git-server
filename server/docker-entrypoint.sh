#!/bin/sh
set -eu

SSH_HOST_KEYS_DIR=/etc/ssh/host-keys
SSH_AUTHORIZED_KEYS_DIR=/etc/ssh/authorized-keys
SSH_AUTHORIZED_KEYS_CMD_USER=nobody

echo "Starting Git Server"

# SSH host keys are generated when missing. Existing keys are never replaced,
# because clients may already know them. Startup fails if a key cannot be loaded,
# allowing the administrator to fix the issue. A missing or incorrect public key
# is regenerated from the private key.
for key_type in ed25519 rsa; do
  key_file="$SSH_HOST_KEYS_DIR/ssh_host_${key_type}_key"
  if [ ! -s "$key_file" ]; then
    echo "Generating $key_type host key pair"
    # an interrupted first start can leave an empty key, ssh-keygen does not overwrite it
    rm -f "$key_file" "$key_file.pub"
    ssh-keygen -q -t "$key_type" -N '' -C '' -f "$key_file"
  fi
  # sshd ignores a private key that group or others can access
  case "$(stat -c %a "$key_file")" in
    600|400) ;;
    *)
      echo "Fixing permissions of $key_file"
      chmod 600 "$key_file"
      ;;
  esac
  if ! public=$(ssh-keygen -y -P '' -f "$key_file"); then
    echo "ERROR: $key_file cannot be loaded, restore the file or delete it to regenerate" >&2
    exit 1
  fi
  # compare the key type and data, ignoring the comment
  expected=$(printf '%s\n' "$public" | cut -d' ' -f1,2)
  if [ "$(cut -d' ' -f1,2 "$key_file.pub" 2>/dev/null)" != "$expected" ]; then
    echo "Repairing $key_file.pub"
    printf '%s\n' "$public" >"$key_file.pub"
  fi
done

# On every login, sshd reads the authorized keys as the AuthorizedKeysCommandUser.
# That user must be able to enter and list the directory, otherwise key-based login fails.
# Access is tried for real: with userns-remap, test -r and -x can give the wrong answer.
# sshd silently ignores unreadable files and invalid keys, so issues are logged here.
cr=$(printf '\r')
if su -s /bin/sh "$SSH_AUTHORIZED_KEYS_CMD_USER" -c 'cd "$1" && ls >/dev/null' \
  sh "$SSH_AUTHORIZED_KEYS_DIR" 2>/dev/null; then
  for file in "$SSH_AUTHORIZED_KEYS_DIR"/*.pub; do
    [ -f "$file" ] || continue
    name=${file##*/}
    # key lines are never logged because a file may accidentally contain a private key
    if ! content=$(su -s /bin/sh "$SSH_AUTHORIZED_KEYS_CMD_USER" -c 'cat "$1"' \
      sh "$file" 2>/dev/null); then
      echo "WARNING: $name is not readable by user $SSH_AUTHORIZED_KEYS_CMD_USER, ignored" >&2
      continue
    fi
    private=
    printf '%s\n' "$content" | while IFS= read -r line; do
      line=${line%"$cr"}
      line=${line#"${line%%[![:space:]]*}"}
      case "$line" in
        ''|'#'*) ;;
        -*'BEGIN '*'PRIVATE KEY'*)
          echo "WARNING: found private key in $name, HINT: remove the file and treat the key as compromised" >&2
          private=yes
          ;;
        -*'END '*'PRIVATE KEY'*) private= ;;
        *)
          [ -z "$private" ] || continue
          if ! printf '%s\n' "$line" | ssh-keygen -l -f - >/dev/null 2>&1; then
            echo "WARNING: found invalid key in $name, ignored" >&2
          fi
          ;;
      esac
    done
  done
else
  echo "WARNING: user $SSH_AUTHORIZED_KEYS_CMD_USER cannot read $SSH_AUTHORIZED_KEYS_DIR" >&2
fi

# The repositories volume must be owned by the git user, otherwise pushes will fail.
git_uid=$(id -u git)
if [ "$(stat -c %u /srv/git)" != "$git_uid" ]; then
  echo "ERROR: /srv/git must be owned by uid=$git_uid (git)" >&2
  exit 1
fi

exec "$@"
