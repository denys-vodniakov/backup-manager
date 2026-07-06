# backup-manager

A secure, production-ready Bash backup manager for Linux hosting environments with SSH access and **no root privileges**. Designed for shared hosting (OVH Web Cloud, cPanel-style layouts, VPS without sudo) but kept generic — not tied to any single provider or CMS.

## What it does

- Creates **timestamped backup directories** with optional **MySQL dumps** and **tar.gz archives**
- Generates **SHA256 checksums** for integrity verification
- Uploads backups to a remote destination via **rclone**
- Applies **local and remote retention** policies
- Provides a **restore** workflow with checksum verification and confirmation prompts
- Writes **human-readable per-run logs** with timestamps, file sizes, and duration

## Supported environments


| Requirement                            | Notes                                                 |
| -------------------------------------- | ----------------------------------------------------- |
| Linux with Bash 4+                     | Tested patterns: Debian/Ubuntu, OVH shared hosting    |
| SSH access                             | No root/sudo required                                 |
| `tar`, `gzip`, `sha256sum` or `shasum` | Standard on most hosts                                |
| `mysqldump` / `mysql`                  | When `ENABLE_MYSQL_BACKUP=true`                       |
| `rclone`                               | When `ENABLE_REMOTE_UPLOAD=true` (user-space install) |


## Security model

- **Secrets stay local.** Only `.env.example` is committed; `.env` is gitignored.
- **Path safety checks** prevent deletion outside configured `BACKUP_DIR`.
- Critical paths must be **absolute**, cannot be `/`, `.`, `..`, or contain `..` components.
- `RESTORE_TARGET_PATH` cannot be the home directory root.
- **Tar-slip protection**: archives are scanned for absolute paths and `..` before extraction.
- **Backup name validation**: restore accepts only `YYYY-MM-DD_HHMMSS` names or paths under `BACKUP_DIR` / `TMP_DIR`.
- `**safe_remove_directory`**: all `rm -rf` operations go through a guarded helper with parent-path checks.
- **Identifier validation** for database names, rclone remotes, and project names.
- `.env` permission warning when group/world-readable (`chmod 600` recommended).
- Webhook payloads are JSON-escaped; only HTTPS webhook URLs are accepted.
- Restore requires explicit confirmation unless `FORCE=true`.
- Database passwords are read from `.env` (set permissions: `chmod 600 .env`).
- `MYSQL_PWD` is used to keep passwords off the command line (still protect `.env`).

### Gitignored paths

```
.env
.env.*
*.sql / *.sql.gz / *.tar.gz
logs/*, tmp/*, backups/*
rclone.conf, .config/
*.pem, *.key, secrets/
```

## Installation

```bash
git clone https://github.com/denys-vodniakov/backup-manager.git ~/backup-manager
cd ~/backup-manager
cp .env.example .env
chmod 600 .env
chmod +x backup.sh restore.sh
```

Edit `.env` with your paths and credentials.

## rclone setup

Install rclone in user space (no root):

```bash
mkdir -p ~/bin
curl -O https://downloads.rclone.org/rclone-current-linux-amd64.zip
# unpack and copy rclone binary to ~/bin/rclone
chmod +x ~/bin/rclone
```

Configure a remote (config stays outside the repo):

```bash
~/bin/rclone config
# Example remote name: myremote
# Use Swift/S3/FTP/SFTP depending on your storage provider
```

Set in `.env`:

```bash
ENABLE_REMOTE_UPLOAD=true
RCLONE_BIN="${HOME}/bin/rclone"
RCLONE_REMOTE="myremote"
RCLONE_REMOTE_PATH="backups/my-website"
RETENTION_REMOTE_DAYS=30
```

## WordPress example

See `[examples/wordpress.env.example](examples/wordpress.env.example)` for a typical shared-hosting WordPress layout:

```bash
cp examples/wordpress.env.example .env
# Edit DB credentials and rclone remote name
chmod 600 .env
./backup.sh
```

Typical paths on OVH Web Cloud:

- WordPress files: `~/www`
- Database: credentials from OVH control panel → Databases

## Cron setup

See `[examples/cron.example](examples/cron.example)`.

**Daily database-only backup** (02:30):

```cron
30 2 * * * cd "$HOME/backup-manager" && ENABLE_FILE_BACKUP=false ENABLE_MYSQL_BACKUP=true ./backup.sh >> "$HOME/backup-manager/logs/cron.log" 2>&1
```

**Weekly full backup** (Sunday 03:00):

```cron
0 3 * * 0 cd "$HOME/backup-manager" && ./backup.sh >> "$HOME/backup-manager/logs/cron.log" 2>&1
```

Each run also creates a timestamped log in `LOG_DIR`.

## Backup usage

```bash
cd ~/backup-manager
./backup.sh
```

Backup output structure:

```
backups/YYYY-MM-DD_HHMMSS/
├── manifest.txt
├── site.tar.gz          # if ENABLE_FILE_BACKUP=true
├── database.sql.gz      # if ENABLE_MYSQL_BACKUP=true
└── checksums.sha256
```

Environment overrides for one-off runs:

```bash
ENABLE_FILE_BACKUP=false ENABLE_MYSQL_BACKUP=true ./backup.sh
```

Exit code is non-zero on failure. Incomplete backup directories are removed automatically.

## Restore usage

```bash
# By backup timestamp name (local or remote)
./restore.sh 2026-07-06_143000

# By full path
./restore.sh ~/backup-manager/backups/2026-07-06_143000

# Non-interactive (automation / CI)
FORCE=true ./restore.sh 2026-07-06_143000
```

Restore workflow:

1. Resolve backup (local dir, or download via rclone if not found locally)
2. Verify SHA256 checksums
3. Confirm before overwriting files and database
4. Extract archive to `RESTORE_TARGET_PATH`
5. Import MySQL dump if present and enabled

## Troubleshooting


| Problem                        | What to check                                                                |
| ------------------------------ | ---------------------------------------------------------------------------- |
| `Environment file not found`   | `cp .env.example .env`                                                       |
| `SOURCE_PATH does not exist`   | Use absolute path; on OVH often `$HOME/www`                                  |
| `mysqldump failed`             | DB host/user/password; OVH uses `localhost`                                  |
| `rclone not found`             | `RCLONE_BIN` path; `chmod +x` on binary                                      |
| `Checksum verification failed` | Corrupt download or tampered files — re-download backup                      |
| Cron silent failures           | Redirect output: `>> logs/cron.log 2>&1`                                     |
| `date -d` errors on macOS      | Scripts target Linux production hosts; local macOS testing may need GNU date |


View latest log:

```bash
ls -t logs/backup-*.log | head -1 | xargs tail -f
```

## Notes for OVH Web Cloud shared hosting

- **No root access** — install rclone to `~/bin`, keep config in `~/.config/rclone/rclone.conf` (gitignored if copied locally).
- **WordPress root** is usually `~/www` (not `public_html` on all plans — verify with `ls ~`).
- **MySQL** host is typically `localhost`; database name/user from the OVH panel.
- **Cron** is configured in the OVH control panel or via `crontab -e` over SSH.
- **Disk quota** — monitor `backups/` size; tune `RETENTION_LOCAL_DAYS`.
- **Remote storage** — OVH Object Storage works well with rclone (Swift backend).

## Project structure

```
backup-manager/
├── backup.sh              # Main backup entry point
├── restore.sh             # Restore entry point
├── .env.example           # Configuration template
├── lib/
│   ├── logger.sh          # Per-run logging
│   ├── safety.sh          # Path validation, safe removal, tar-slip checks
│   ├── env.sh             # Config load & validation
│   ├── mysql.sh           # mysqldump / restore
│   ├── archive.sh         # tar.gz create / extract
│   ├── rclone.sh          # Remote upload / download / retention
│   ├── checksum.sh        # SHA256 generate / verify
│   └── retention.sh       # Local retention
├── examples/
│   ├── wordpress.env.example
│   └── cron.example
├── logs/
├── tmp/
└── backups/
```

## License

MIT — see [LICENSE](LICENSE) if included in your fork.

## Contributing

Issues and pull requests welcome. Do not commit real credentials, domains, or server-specific paths.