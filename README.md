# sshid-sync

Keeps `~/.ssh/authorized_keys` in sync with your [sshid.io](https://sshid.io) passkey list, merged with a local file of manually-managed keys. Runs hourly via cron (Linux/Synology/UnifiOS) or launchd (macOS).

## How it works

On each run the script:

1. Downloads your public keys from sshid.io
2. Validates both the downloaded keys and your manual keys file (using `ssh-keygen` if available, otherwise a loose prefix check)
3. Assembles the result into a temp file
4. Diffs the temp file against the current `authorized_keys` — skips the write if nothing changed
5. Atomically replaces `authorized_keys` via `mv`

If the download fails or either file is invalid, the script aborts and leaves `authorized_keys` untouched.

### Files under `~/.ssh/`

| File | Purpose |
|---|---|
| `authorized_keys` | Generated — do not edit directly |
| `authorized_keys.manual` | Your hand-managed keys — edit this |
| `authorized_keys.sshid` | Last downloaded sshid.io keys (cache) |
| `sshid-sync.log` | Run log, rotated at 500 lines |

## Deploy

### Initial install on any server

```sh
curl -fsSL https://raw.githubusercontent.com/JamesRadley/sshid/main/sshid-sync.sh | bash -s -- --install
```

This will:
- Auto-detect the platform (macOS / Linux / Synology / UnifiOS)
- Copy the script to the right location
- Install the hourly scheduler (launchd on macOS, cron elsewhere)
- Back up any existing `authorized_keys` to `authorized_keys.presshid.<timestamp>`
- Print a pre-flight checklist

### Override platform detection

```sh
SSHID_PLATFORM=unifi curl -fsSL ... | bash -s -- --install
```

Supported values: `macos`, `linux`, `synology`, `unifi`

### Script locations by platform

| Platform | Location |
|---|---|
| macOS | `~/.local/bin/sshid-sync.sh` |
| Ubuntu / Synology | `~/.local/bin/sshid-sync.sh` |
| UnifiOS (root) | `/data/sshid-sync.sh` |

## Update

To pull the latest version of the script on an already-installed server:

```sh
sshid-sync.sh --update
```

This downloads the script from GitHub, checks its syntax, and re-runs `--install`.

## Pre-flight: migrating existing keys

Before the first sync runs, any keys already in `authorized_keys` that are **not** from sshid.io must be copied to `~/.ssh/authorized_keys.manual` — otherwise they will be overwritten.

The `--install` step backs up the existing file to `authorized_keys.presshid.<timestamp>` so you can refer to it. Example migration:

```sh
# Review the backup
cat ~/.ssh/authorized_keys.presshid.*

# Copy any manual (non-sshid) keys into the manual file
nano ~/.ssh/authorized_keys.manual

# Run a manual sync to verify everything looks right
sshid-sync.sh
cat ~/.ssh/authorized_keys
cat ~/.ssh/sshid-sync.log
```

## Configuration

Edit the variables at the top of `sshid-sync.sh`:

| Variable | Default | Description |
|---|---|---|
| `SSHID_URL` | `https://sshid.io/jamesradley/` | Your sshid.io public key URL |
| `SCRIPT_URL` | GitHub raw URL | Used by `--update` to fetch the latest script |
| `DOWNLOAD_TIMEOUT` | `30` | Seconds before aborting the download |
| `LOG_MAX_LINES` | `500` | Log file is trimmed to half this when exceeded |

## Security considerations

- **Download failure is safe** — the script aborts entirely if sshid.io is unreachable, returning an error, leaving `authorized_keys` unchanged.
- **Atomic write** — `authorized_keys` is replaced via `mv` from a temp file. SSH never sees a partial write.
- **Validation before write** — both input files are checked for valid key format before anything is written.
- **Minimum key count** — if sshid.io returns zero valid keys the script aborts.
- **Permissions** — `authorized_keys` and input files are always set to `600`; `~/.ssh` to `700`.
- **Max download size** — 1 MB cap on the sshid.io response to guard against runaway or wrong-endpoint responses.
