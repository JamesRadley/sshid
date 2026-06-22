#!/usr/bin/env bash

# ---- Configuration ----
SSHID_URL="https://sshid.io/jamesradley/"
SCRIPT_URL="https://raw.githubusercontent.com/JamesRadley/sshid/main/sshid-sync.sh"
DOWNLOAD_TIMEOUT=30
LOG_MAX_LINES=500

# ---- Paths ----
SSH_DIR="${HOME}/.ssh"
MANUAL_KEYS="${SSH_DIR}/authorized_keys.manual"
SSHID_KEYS="${SSH_DIR}/authorized_keys.sshid"
AUTH_KEYS="${SSH_DIR}/authorized_keys"
TMP_KEYS="${SSH_DIR}/authorized_keys.tmp"
LOG_FILE="${SSH_DIR}/sshid-sync.log"

VALID_KEY_PREFIXES="ssh-rsa ssh-dss ssh-ed25519 ecdsa-sha2-nistp256 ecdsa-sha2-nistp384 ecdsa-sha2-nistp521 sk-ssh-ed25519@openssh.com sk-ecdsa-sha2-nistp256@openssh.com"

# ---- Logging ----

log() {
    local level="$1"; shift
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" >> "${LOG_FILE}"
}

rotate_log() {
    [ -f "${LOG_FILE}" ] || return 0
    local lines
    lines=$(wc -l < "${LOG_FILE}" 2>/dev/null) || return 0
    if [ "${lines}" -gt "${LOG_MAX_LINES}" ]; then
        tail -n $((LOG_MAX_LINES / 2)) "${LOG_FILE}" > "${LOG_FILE}.rot" \
            && mv "${LOG_FILE}.rot" "${LOG_FILE}"
    fi
}

# ---- Cleanup ----

cleanup() {
    rm -f "${TMP_KEYS}" "${SSH_DIR}/authorized_keys.sshid.tmp"
}
trap cleanup EXIT

# ---- Validation ----

validate_keys_file() {
    local file="$1"
    local label="$2"

    # Empty file is acceptable (manual keys file may be empty)
    [ -s "${file}" ] || return 0

    # File containing only comments/blank lines is also acceptable
    grep -qvE '^[[:space:]]*(#|$)' "${file}" || return 0

    # Prefer ssh-keygen if available
    if command -v ssh-keygen >/dev/null 2>&1; then
        if ssh-keygen -l -f "${file}" >/dev/null 2>&1; then
            return 0
        fi
        log "ERROR" "${label}: failed ssh-keygen validation"
        return 1
    fi

    # Loose fallback: every non-empty, non-comment line must start with a known key type
    local line_num=0
    while IFS= read -r line; do
        line_num=$((line_num + 1))
        [ -z "${line}" ] && continue
        case "${line}" in '#'*) continue ;; esac

        local matched=0
        for prefix in ${VALID_KEY_PREFIXES}; do
            case "${line}" in "${prefix} "*) matched=1; break ;; esac
        done

        if [ "${matched}" -eq 0 ]; then
            log "ERROR" "${label}: invalid entry at line ${line_num}: ${line:0:60}"
            return 1
        fi
    done < "${file}"

    return 0
}

count_keys() {
    local file="$1"
    [ -f "${file}" ] || { echo 0; return; }
    local n
    n=$(grep -cE '^(ssh-|ecdsa-|sk-)' "${file}" 2>/dev/null) || n=0
    echo "${n}"
}

# ---- Download ----

download_sshid_keys() {
    local tmp="${SSH_DIR}/authorized_keys.sshid.tmp"

    if command -v curl >/dev/null 2>&1; then
        curl --silent --fail --show-error \
            --max-time "${DOWNLOAD_TIMEOUT}" \
            --max-filesize 1048576 \
            --output "${tmp}" \
            "${SSHID_URL}" 2>>"${LOG_FILE}" || {
            log "ERROR" "curl failed downloading ${SSHID_URL}"
            return 1
        }
    elif command -v wget >/dev/null 2>&1; then
        wget --quiet \
            --timeout="${DOWNLOAD_TIMEOUT}" \
            --output-document="${tmp}" \
            "${SSHID_URL}" 2>>"${LOG_FILE}" || {
            log "ERROR" "wget failed downloading ${SSHID_URL}"
            return 1
        }
        # wget lacks --max-filesize; enforce manually
        local size
        size=$(wc -c < "${tmp}" 2>/dev/null) || size=0
        if [ "${size}" -gt 1048576 ]; then
            log "ERROR" "Download exceeded 1MB limit (${size} bytes) — aborting"
            return 1
        fi
    else
        log "ERROR" "Neither curl nor wget is available"
        return 1
    fi

    if [ ! -s "${tmp}" ]; then
        log "ERROR" "Downloaded file is empty"
        return 1
    fi

    mv "${tmp}" "${SSHID_KEYS}"
    chmod 600 "${SSHID_KEYS}"
}

# ---- Sync ----

do_sync() {
    rotate_log

    # Ensure ~/.ssh exists
    if [ ! -d "${SSH_DIR}" ]; then
        mkdir -p "${SSH_DIR}"
        chmod 700 "${SSH_DIR}"
    fi

    # Auto-create manual keys file on first run
    if [ ! -f "${MANUAL_KEYS}" ]; then
        printf '# Manual SSH keys — edit this file by hand\n# sshid-sync will never overwrite it\n' \
            > "${MANUAL_KEYS}"
        chmod 600 "${MANUAL_KEYS}"
        log "INFO" "Created ${MANUAL_KEYS}"
    fi

    # Download sshid.io keys
    if ! download_sshid_keys; then
        log "ERROR" "Aborting: authorized_keys unchanged"
        return 1
    fi

    # Validate both files
    if ! validate_keys_file "${SSHID_KEYS}" "authorized_keys.sshid"; then
        log "ERROR" "Aborting: sshid keys invalid, authorized_keys unchanged"
        return 1
    fi

    if ! validate_keys_file "${MANUAL_KEYS}" "authorized_keys.manual"; then
        log "ERROR" "Aborting: manual keys invalid, authorized_keys unchanged"
        return 1
    fi

    # Require at least one sshid key
    local sshid_count
    sshid_count=$(count_keys "${SSHID_KEYS}")
    if [ "${sshid_count}" -eq 0 ]; then
        log "ERROR" "Aborting: no valid keys returned by sshid.io, authorized_keys unchanged"
        return 1
    fi

    # Assemble into temp file
    {
        printf '# Generated by sshid-sync — do not edit directly\n'
        printf '# Manual keys: %s\n' "${MANUAL_KEYS}"
        printf '# SSHID keys:  %s\n' "${SSHID_KEYS}"
        printf '#\n# --- manual keys ---\n'
        cat "${MANUAL_KEYS}"
        printf '\n# --- sshid.io keys ---\n'
        cat "${SSHID_KEYS}"
    } > "${TMP_KEYS}"
    chmod 600 "${TMP_KEYS}"

    # Skip write if nothing changed
    if [ -f "${AUTH_KEYS}" ] && diff -q "${AUTH_KEYS}" "${TMP_KEYS}" >/dev/null 2>&1; then
        log "INFO" "No changes (${sshid_count} sshid keys) — authorized_keys unchanged"
        return 0
    fi

    # Atomic replace
    mv "${TMP_KEYS}" "${AUTH_KEYS}"
    chmod 600 "${AUTH_KEYS}"

    local manual_count
    manual_count=$(count_keys "${MANUAL_KEYS}")
    log "INFO" "Updated authorized_keys (${sshid_count} sshid keys, ${manual_count} manual keys)"
}

# ---- Platform detection ----

detect_platform() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux)
            if [ -f /etc/synoinfo.conf ] \
               || grep -qi "synology" /etc/issue 2>/dev/null; then
                echo "synology"
            elif [ -f /usr/bin/ubnt-device-info ] \
               || grep -qi "unifi" /etc/issue 2>/dev/null \
               || grep -qi "ubnt" /etc/issue 2>/dev/null; then
                echo "unifi"
            else
                echo "linux"
            fi
            ;;
        *) echo "linux" ;;
    esac
}

# ---- Scheduler installation ----

install_cron() {
    local script_path="$1"
    local cron_line="0 * * * * ${script_path}"

    if command -v crontab >/dev/null 2>&1; then
        # Standard crontab approach
        if crontab -l 2>/dev/null | grep -qF "sshid-sync"; then
            echo "Cron entry already present — skipping"
            return
        fi
        # crontab - (stdin) is not universally supported; use a temp file
        local tmpfile
        tmpfile=$(mktemp)
        ( crontab -l 2>/dev/null || true; echo "${cron_line}" ) > "${tmpfile}"
        crontab "${tmpfile}"
        rm -f "${tmpfile}"
        echo "Added cron entry: ${cron_line}"
    else
        # Fallback for Synology and other systems without the crontab binary.
        # Cron still runs and reads /var/spool/cron/crontabs/<user> directly.
        local cron_user
        cron_user="${USER:-$(id -un)}"
        local crontab_dir="/var/spool/cron/crontabs"
        local crontab_file="${crontab_dir}/${cron_user}"

        if [ -f "${crontab_file}" ] && grep -qF "sshid-sync" "${crontab_file}" 2>/dev/null; then
            echo "Cron entry already present — skipping"
            return
        fi

        if mkdir -p "${crontab_dir}" 2>/dev/null \
           && echo "${cron_line}" >> "${crontab_file}" 2>/dev/null; then
            chmod 600 "${crontab_file}" 2>/dev/null || true
            # Signal crond to reload if we can find its PID
            for pidfile in /var/run/crond.pid /var/run/cron.pid; do
                [ -f "${pidfile}" ] && kill -HUP "$(cat "${pidfile}")" 2>/dev/null && break
            done
            echo "Added cron entry to ${crontab_file}: ${cron_line}"
        else
            echo "WARNING: could not write crontab automatically."
            echo "Add this line to your crontab manually:"
            echo "  ${cron_line}"
        fi
    fi
}

install_launchd() {
    local script_path="$1"
    local plist_dir="${HOME}/Library/LaunchAgents"
    local plist_path="${plist_dir}/io.sshid.sync.plist"

    mkdir -p "${plist_dir}"
    cat > "${plist_path}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.sshid.sync</string>
    <key>ProgramArguments</key>
    <array>
        <string>${script_path}</string>
    </array>
    <key>StartInterval</key>
    <integer>3600</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>
</dict>
</plist>
PLIST

    launchctl unload "${plist_path}" 2>/dev/null || true
    launchctl load "${plist_path}"
    echo "Installed launchd plist: ${plist_path}"
}

# ---- Install ----

do_install() {
    local platform="${SSHID_PLATFORM:-$(detect_platform)}"
    echo "Platform: ${platform}"

    local script_dest
    case "${platform}" in
        unifi) script_dest="/data/sshid-sync.sh" ;;
        *)     script_dest="${HOME}/.local/bin/sshid-sync.sh" ;;
    esac

    mkdir -p "$(dirname "${script_dest}")"

    # When piped through curl | bash, $0 is 'bash' not the script file.
    # In that case download directly to the destination.
    if [ -f "$0" ]; then
        cp "$0" "${script_dest}"
    else
        echo "Downloading script to ${script_dest}..."
        if command -v curl >/dev/null 2>&1; then
            curl --silent --fail --show-error \
                --max-time "${DOWNLOAD_TIMEOUT}" \
                --output "${script_dest}" \
                "${SCRIPT_URL}" || {
                echo "ERROR: failed to download script from ${SCRIPT_URL}" >&2
                return 1
            }
        elif command -v wget >/dev/null 2>&1; then
            wget --quiet --timeout="${DOWNLOAD_TIMEOUT}" \
                --output-document="${script_dest}" \
                "${SCRIPT_URL}" || {
                echo "ERROR: failed to download script from ${SCRIPT_URL}" >&2
                return 1
            }
        else
            echo "ERROR: neither curl nor wget available" >&2
            return 1
        fi
    fi

    chmod 755 "${script_dest}"
    echo "Installed to: ${script_dest}"

    # Back up any existing authorized_keys before first sync can overwrite it
    local backup_note=""
    if [ -f "${AUTH_KEYS}" ]; then
        local backup="${AUTH_KEYS}.presshid.$(date '+%Y%m%d_%H%M%S')"
        cp "${AUTH_KEYS}" "${backup}"
        chmod 600 "${backup}"
        backup_note="Backed up existing authorized_keys to: ${backup}"
        echo "${backup_note}"
    fi

    case "${platform}" in
        macos) install_launchd "${script_dest}" ;;
        *)     install_cron "${script_dest}" ;;
    esac

    cat <<CHECKLIST

===== Pre-flight checklist =====
${backup_note:+Your existing authorized_keys has been backed up (see above).
}If that backup contains keys that are NOT from sshid.io (manual keys you
added), copy them to:

    ${MANUAL_KEYS}

...before the first sync runs. The first sync will overwrite authorized_keys.

Next steps:
  1. Migrate any existing manual keys to: ${MANUAL_KEYS}
  2. Run a manual sync to verify:        ${script_dest}
  3. Check the log at:                   ${LOG_FILE}

To override platform detection: SSHID_PLATFORM=unifi ${script_dest} --install
=================================
CHECKLIST
}

# ---- Update ----

do_update() {
    local platform="${SSHID_PLATFORM:-$(detect_platform)}"
    local script_dest
    case "${platform}" in
        unifi) script_dest="/data/sshid-sync.sh" ;;
        *)     script_dest="${HOME}/.local/bin/sshid-sync.sh" ;;
    esac

    # Download alongside the installed script, not to /tmp — /tmp may be noexec
    local tmp="${script_dest}.new"

    echo "Downloading latest sshid-sync from GitHub..."
    if command -v curl >/dev/null 2>&1; then
        curl --silent --fail --show-error \
            --max-time "${DOWNLOAD_TIMEOUT}" \
            --output "${tmp}" \
            "${SCRIPT_URL}" || {
            echo "ERROR: download failed" >&2
            rm -f "${tmp}"
            return 1
        }
    elif command -v wget >/dev/null 2>&1; then
        wget --quiet --timeout="${DOWNLOAD_TIMEOUT}" \
            --output-document="${tmp}" \
            "${SCRIPT_URL}" || {
            echo "ERROR: download failed" >&2
            rm -f "${tmp}"
            return 1
        }
    else
        echo "ERROR: neither curl nor wget available" >&2
        return 1
    fi

    if ! bash -n "${tmp}" 2>/dev/null; then
        echo "ERROR: downloaded script failed syntax check — aborting update" >&2
        rm -f "${tmp}"
        return 1
    fi

    chmod 755 "${tmp}"
    mv "${tmp}" "${script_dest}"
    echo "Updated ${script_dest}"
    exec "${script_dest}" --install
}

# ---- Entry point ----

case "${1:-}" in
    --install) do_install ;;
    --update)  do_update ;;
    --help|-h)
        cat <<USAGE
Usage: $(basename "$0") [--install | --update | --help]
  (no args)   Run the SSH key sync now
  --install   Install to system path and schedule hourly job
  --update    Download latest version from GitHub and reinstall
  --help      Show this message

Override platform detection:
  SSHID_PLATFORM=unifi $(basename "$0") --install
  SSHID_PLATFORM=macos $(basename "$0") --install
USAGE
        ;;
    *) do_sync ;;
esac
