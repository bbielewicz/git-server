# Git Server

A small Git server running in a Docker container, designed for one person or a small,
trusted team. Users authenticate over SSH with their public keys and can clone, fetch and
push repositories, nothing else.

- All users log in as `git`, with [git-shell](https://git-scm.com/docs/git-shell) as the
  login shell.
- Interactive shells, file transfer, port forwarding and terminal sessions are disabled.
- Every authorized key can read and write every repository.
- Repositories can be created or removed only by the administrator.
- Force pushes and branch deletions are rejected by default.

## Quick start

The commands in this readme should be run from the project root, the folder that contains
`compose.yaml`.

1. Create the configuration file from `.env.example`, which documents each setting, and then
   adjust it as needed:

   ```sh
   cp .env.example .env
   ```

2. Create a folder for the users' public keys and add the keys as described in
   [Managing user keys](#managing-user-keys):

   ```sh
   mkdir -m 755 authorized-keys
   cp <public-key-file> authorized-keys/<user>.pub
   chmod 644 authorized-keys/<user>.pub
   ```

3. Build the image and start the server:

   ```sh
   docker compose build
   docker compose up -d
   ```

4. Create a repository and clone it, here using the default address and port from
   `.env.example`:

   ```sh
   docker compose exec -u git server git init --bare /srv/git/example.git
   git clone ssh://git@127.0.0.1:2222/srv/git/example.git
   ```

   On the first connection, the SSH client asks whether to trust the server's host key,
   which can be checked as described in [Host keys](#host-keys).

## Updating the image

The command `docker compose up` never pulls or rebuilds the image. It builds the image only
when it is missing.
Security fixes for Alpine, Git and OpenSSH reach the server only when the image is rebuilt
without the cache:

```sh
docker compose build --pull --no-cache
docker compose up -d
```

After changing files in `server/`, `docker compose build` without these options is enough.

### Changing the git user's UID

The repositories must belong to the `git` user; otherwise the server does not start. After
changing `GIT_SERVER_UID` or `GIT_SERVER_GID` in `.env`, the image has to be rebuilt and the
owner of the repositories changed before the server is started again:

```sh
docker compose build
docker compose stop
docker run --rm --network none -v git-server-repositories:/srv/git alpine chown -R <uid>:<gid> /srv/git
docker compose up -d
```

## Managing user keys

The users' public keys are stored in `*.pub` files in the folder set by
`GIT_SERVER_SSH_AUTHORIZED_KEYS_DIR` in `.env` (`./authorized-keys` by default). Usually each
key has its own file, named after the user it belongs to. Keys are read on every
login, so adding or removing a file takes effect immediately, without a restart.

- Keys must be in OpenSSH format, one line per key: `ssh-ed25519 AAAA... alice@laptop`.
  For PuTTY keys, this is the text under "Public key for pasting into OpenSSH
  authorized_keys file", not the `.ppk` file, which contains the private key as well.
- The folder and the files must be readable by everyone (`chmod 755` and `644`), because the
  keys are read as the user `nobody`.
- Anyone who can write to the folder can give themselves access. It should be writable by
  the administrator only.

### Checking the keys

At login, sshd silently ignores unreadable files and invalid keys, so the server checks them
at every start and logs the problems it finds. To run the check again after changing keys,
without a restart:

```sh
docker compose exec server docker-entrypoint.sh true
```

### Finding which key was used

Every login is recorded in the container log, together with the fingerprint of the key used.
The file a fingerprint belongs to can be found by listing the fingerprints of all key files
on the host:

```sh
for f in ./authorized-keys/*.pub; do echo "$f"; ssh-keygen -lf "$f"; done
```

## Host keys

The server's host keys (Ed25519 and RSA) are generated on the first start and kept in the
volume `git-server-ssh-host-keys`. The fingerprint shown by the SSH client on the first
connection can be checked with:

```sh
docker compose exec server ssh-keygen -lf /etc/ssh/host-keys/ssh_host_ed25519_key.pub
docker compose exec server ssh-keygen -lf /etc/ssh/host-keys/ssh_host_rsa_key.pub
```

An existing key is never replaced. If a private key cannot be loaded, the server does not
start: the key has to be restored from a backup or deleted to get a new one on the next
start.
After a new key is generated, clients that know the old key refuse to connect until it is
removed from their `known_hosts` file.

## Managing repositories

Repositories are stored in the volume `git-server-repositories`, mounted at `/srv/git`.
The commands below must be run as the `git` user, who owns the repositories. When run as root,
they fail with "Permission denied", because root's capabilities are dropped.

Create a repository, optionally in a folder. Missing folders are created, and the default
branch is `main`:

```sh
docker compose exec -u git server git init --bare /srv/git/<name>.git
docker compose exec -u git server git init --bare /srv/git/<folder>/<name>.git
```

List the repositories:

```sh
docker compose exec server find /srv/git -name '.*' -prune -o -type d -name '*.git' -print -prune | sort
```

Remove a repository (**this deletes it for good**):

```sh
docker compose exec -u git server rm -rf /srv/git/<name>.git
```

## Connecting to the server

```sh
git clone ssh://git@<GIT_SERVER_IP_ADDRESS>:<GIT_SERVER_SSH_PORT>/srv/git/<name>.git
```

The server allows three authentication attempts per connection. If the SSH agent holds more
than three keys, the login can fail with "Too many authentication failures" before the right
key is tried. This can be fixed by setting the key with `IdentityFile` and
`IdentitiesOnly yes` in `~/.ssh/config`.

Partial clones (for example, `git clone --filter=blob:none`) need Git protocol version 2 to
fetch the missing objects later.

## Repository settings

The server-wide Git settings are in `server/gitconfig`. A repository's own config can override
them, for example, to accept an old repository with known problems by relaxing only the
failing check, or to raise the push size limit of 1 GB:

```sh
docker compose exec -u git server git -C /srv/git/<name>.git config receive.fsck.zeroPaddedFilemode ignore
docker compose exec -u git server git -C /srv/git/<name>.git config receive.maxInputSize 4g
```

### Large files

The 256 MB memory limit in `compose.yaml` is enough for source code. Large files need more:
with four versions of a 60 MB file, `git gc` and `git clone` need more than 512 MB; 1 GB
works. When Git runs out of memory, its process is killed: the push is rejected or the clone
fails, but the repository stays consistent. For repositories with large files, `mem_limit`
and `memswap_limit` in `compose.yaml` can be raised (both kept equal, so there is no swap),
or Git's memory use can be limited per repository:

```sh
docker compose exec -u git server git -C /srv/git/<name>.git config core.bigFileThreshold 32m
docker compose exec -u git server git -C /srv/git/<name>.git config pack.threads 1
docker compose exec -u git server git -C /srv/git/<name>.git config pack.windowMemory 64m
docker compose exec -u git server git -C /srv/git/<name>.git config pack.deltaCacheSize 32m
```

## History protection

Force pushes and branch deletions are rejected by default (`receive.denyNonFastForwards` and
`receive.denyDeletes` in `server/gitconfig`). Tags are not protected, as in plain Git. Only
the administrator can change the protection of a repository. The settings are stored in the
repository, so they are part of the backup.

Allow deleting branches while force pushes stay rejected:

```sh
docker compose exec -u git server git -C /srv/git/<name>.git config receive.denyDeletes false
```

Switch the protection off completely:

```sh
docker compose exec -u git server git -C /srv/git/<name>.git config receive.denyNonFastForwards false
docker compose exec -u git server git -C /srv/git/<name>.git config receive.denyDeletes false
```

Switch it on again, back to the default:

```sh
docker compose exec -u git server git -C /srv/git/<name>.git config --unset receive.denyNonFastForwards
docker compose exec -u git server git -C /srv/git/<name>.git config --unset receive.denyDeletes
```

Show the current settings (`true` means protected):

```sh
docker compose exec -u git server git -C /srv/git/<name>.git config --get receive.denyNonFastForwards
docker compose exec -u git server git -C /srv/git/<name>.git config --get receive.denyDeletes
```

## Customizing the SSH server

The configuration file `server/sshd_config` includes `/etc/ssh/sshd_config.d/*.conf` before
its own settings, so sshd settings can be changed without rebuilding the image. A folder
with `*.conf` files can be mounted there by adding it to the `volumes` of the `server`
service in `compose.yaml` and running `docker compose up -d`:

```yaml
services:
  server:
    volumes:
      # existing entries stay unchanged
      - ./sshd_config.d:/etc/ssh/sshd_config.d:ro
```

- The included values win, except for settings that can be repeated, like `AcceptEnv`: those
  are added to the server's values.
- The folder and the files must be readable by everyone (`chmod 755` and `644`).
- An override can weaken the server's security, for example, by allowing passwords or sftp.

Since sshd reads the files only when it starts, the server has to be restarted after a change.
Checking the effective configuration first also reports errors in the files:

```sh
docker compose exec server sshd -T
docker compose restart server
```

## Backup and restore

A backup is a copy of the two volumes, `git-server-ssh-host-keys` and
`git-server-repositories`, made while the server is stopped, so every repository is
consistent. The authorized keys folder, `.env` and `compose.yaml` are files on the host and
have to be backed up separately.

### Creating a backup

```sh
docker compose stop
(umask 077; docker run --rm --network none \
  -v git-server-ssh-host-keys:/backup/ssh-host-keys:ro \
  -v git-server-repositories:/backup/repositories:ro \
  alpine tar -c -f - -C /backup . > git-server-backup-$(date +%F).tar)
docker compose start
```

The archive contains the server's private host keys, so `umask 077` makes it readable by its
owner only. Its contents can be listed with `tar -tvf git-server-backup-<date>.tar`.

### Restoring a backup

**This replaces the current data.** On a new host, the image has to be built first,
using `docker compose build`.

```sh
docker compose down
docker volume rm git-server-ssh-host-keys git-server-repositories  # deletes the current data
docker compose create
docker run --rm -i --network none \
  -v git-server-ssh-host-keys:/backup/ssh-host-keys \
  -v git-server-repositories:/backup/repositories \
  alpine tar -x -f - -C /backup < git-server-backup-<date>.tar
docker compose start
```

The command `docker compose create` creates the empty volumes without starting the server.
Owners are restored as numeric IDs: restoring into a server built with a different UID
requires changing the owner as described in
[Changing the git user's UID](#changing-the-git-users-uid).
