#!/bin/bash
# Install an unofficial self-built Tailscale daemon on macOS.
# This is intended for internal/security use when the official signed
# package is blocked by MDM policy and you need to run a locally-built,
# self-codesigned copy until the allow-list is updated.
#
# Usage:
#   tar -xzf tailscale-macos-universal.tar.gz
#   sudo ./install-macos-selfsigned.sh
#
# Auto-update (used by the updater LaunchDaemon):
#   sudo ./install-macos-selfsigned.sh --auto-update

set -euo pipefail

TAILSCALED_BIN="/usr/local/bin/tailscaled"
TAILSCALE_BIN="/usr/local/bin/tailscale"
SYS_PLIST="/Library/LaunchDaemons/com.tailscale.tailscaled.plist"
SERVICE="com.tailscale.tailscaled"
STATE_DIR="/Library/Tailscale"
GITHUB_REPO="Rahulsharma0810/tailscale-macos-selfsigned"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "This installer is for macOS only." >&2
    exit 1
fi

AUTO_UPDATE=0
INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_SELF="${INSTALL_DIR}/$(basename "$0")"
EXTRACT_DIR="${INSTALL_DIR}"
BIN_SRC="${INSTALL_DIR}/bin"

# Handle --auto-update mode: fetch latest nightly release from GitHub.
if [ "${1:-}" = "--auto-update" ]; then
    AUTO_UPDATE=1
    echo "==> Auto-update mode enabled."
    echo "==> Fetching latest nightly release..."

    RELEASE_URL="https://github.com/${GITHUB_REPO}/releases/download/nightly/tailscale-macos-universal.tar.gz"

    EXTRACT_DIR="/tmp/tailscale-update-$$"
    rm -rf "${EXTRACT_DIR}"
    mkdir -p "${EXTRACT_DIR}"
    cd "${EXTRACT_DIR}"

    if ! curl -fSL --retry 3 -o tailscale-macos-universal.tar.gz "${RELEASE_URL}"; then
        echo "ERROR: failed to download nightly release from ${RELEASE_URL}" >&2
        rm -rf "${EXTRACT_DIR}"
        exit 1
    fi

    tar -xzf tailscale-macos-universal.tar.gz
    BIN_SRC="${EXTRACT_DIR}/bin"

    # Keep a copy of the freshly-shipped installer so the daemon can self-update.
    if [ -f "${EXTRACT_DIR}/install-macos-selfsigned.sh" ]; then
        SCRIPT_SELF="${EXTRACT_DIR}/install-macos-selfsigned.sh"
    fi
    chmod +x "${SCRIPT_SELF}" 2>/dev/null || true
fi

if [ ! -f "${BIN_SRC}/tailscaled" ]; then
    echo "Cannot find '${BIN_SRC}/tailscaled'. Run this from the extracted tarball root." >&2
    exit 1
fi

if [ "$(id -u)" != "0" ]; then
    echo "This installer must run as root. Re-run with: sudo $0 ${*:-}" >&2
    exit 1
fi

echo "==> Installing tailscaled binary to ${TAILSCALED_BIN}..."
mkdir -p /usr/local/bin
# Atomic-ish replace so a running daemon isn't corrupted mid-copy.
cp -f "${BIN_SRC}/tailscaled" "${TAILSCALED_BIN}.tmp"
chmod 755 "${TAILSCALED_BIN}.tmp"
mv -f "${TAILSCALED_BIN}.tmp" "${TAILSCALED_BIN}"

echo "==> Linking tailscale CLI -> tailscaled..."
# The binary was built with --box (ts_include_cli): invoked as `tailscale`
# it acts as the CLI, otherwise as the daemon.
ln -sf tailscaled "${TAILSCALE_BIN}"

echo "==> Self-codesigning the binary..."
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Self-Signed Tailscale/ {print $2; exit}')
if [ -n "${IDENTITY}" ]; then
    codesign --force --sign "${IDENTITY}" --identifier com.tailscale.tailscaled "${TAILSCALED_BIN}"
else
    echo "No 'Self-Signed Tailscale' identity found; using ad-hoc signature (-)." >&2
    codesign --force --sign - "${TAILSCALED_BIN}"
fi

echo "==> Removing quarantine attributes..."
xattr -dr com.apple.quarantine "${TAILSCALED_BIN}" 2>/dev/null || true

mkdir -p "${STATE_DIR}"

# Use Tailscale's built-in daemon installer, which writes the launchd plist
# and loads+starts the service. Fall back to a hand-written plist if the
# built-in path fails for any reason.
echo "==> Installing LaunchDaemon..."
if "${TAILSCALED_BIN}" install-system-daemon 2>/dev/null; then
    echo "Installed via 'tailscaled install-system-daemon'."
else
    echo "Built-in install-system-daemon failed; writing plist manually." >&2
    launchctl bootout system "${SYS_PLIST}" 2>/dev/null || true
    tee "${SYS_PLIST}" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${SERVICE}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${TAILSCALED_BIN}</string>
        <string>--state=${STATE_DIR}/tailscaled.state</string>
        <string>--socket=/var/run/tailscaled.socket</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${STATE_DIR}/tailscaled.log</string>
    <key>StandardErrorPath</key>
    <string>${STATE_DIR}/tailscaled.log</string>
</dict>
</plist>
PLIST
    chmod 644 "${SYS_PLIST}"
    launchctl bootstrap system "${SYS_PLIST}" 2>/dev/null || \
        launchctl load -w "${SYS_PLIST}" 2>/dev/null || true
fi

# Wait for the control socket to come up.
echo "==> Waiting for tailscaled to be ready..."
for i in $(seq 1 15); do
    if "${TAILSCALE_BIN}" status >/dev/null 2>&1; then
        break
    fi
    # `status` exits non-zero when logged out too; check the daemon socket instead.
    if "${TAILSCALE_BIN}" status 2>&1 | grep -qiE 'logged out|stopped|NeedsLogin'; then
        break
    fi
    sleep 1
done

# Bring the node up with interactive browser login (unless already logged in).
if "${TAILSCALE_BIN}" status 2>/dev/null | grep -qiv 'logged out' \
   && "${TAILSCALE_BIN}" status >/dev/null 2>&1; then
    echo "==> Already logged in; skipping 'tailscale up'."
else
    echo "==> Bringing Tailscale up (interactive browser login)..."
    echo "    A login URL will be printed below. Open it in a browser to authenticate."
    "${TAILSCALE_BIN}" up || {
        echo "'tailscale up' did not complete. You can retry manually with:"
        echo "  sudo tailscale up"
    }
fi

# ---- Self-updater LaunchDaemon (root-owned, runs daily at 04:00) ----
echo "==> Installing self-updater LaunchDaemon..."
UPDATER_SCRIPT="${STATE_DIR}/tailscale-update.sh"
if [ "${SCRIPT_SELF}" != "${UPDATER_SCRIPT}" ]; then
    cp -f "${SCRIPT_SELF}" "${UPDATER_SCRIPT}"
    chown root:wheel "${UPDATER_SCRIPT}"
    chmod 755 "${UPDATER_SCRIPT}"
fi

UPDATER_PLIST="/Library/LaunchDaemons/com.tailscale.tailscaled.updater.plist"
launchctl bootout system "${UPDATER_PLIST}" 2>/dev/null || true
tee "${UPDATER_PLIST}" >/dev/null <<UPDATER
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.tailscale.tailscaled.updater</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${UPDATER_SCRIPT}</string>
        <string>--auto-update</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>4</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>${STATE_DIR}/updater.log</string>
    <key>StandardErrorPath</key>
    <string>${STATE_DIR}/updater.log</string>
</dict>
</plist>
UPDATER
chown root:wheel "${UPDATER_PLIST}"
chmod 644 "${UPDATER_PLIST}"
launchctl bootout system "${UPDATER_PLIST}" 2>/dev/null || true
launchctl bootstrap system "${UPDATER_PLIST}" 2>/dev/null || \
    launchctl load -w "${UPDATER_PLIST}" 2>/dev/null || true

launchctl list | grep -q "com.tailscale.tailscaled.updater" \
    && echo "Updater LaunchDaemon loaded." \
    || echo "Updater LaunchDaemon will load on next boot."

echo ""
echo "Tailscale has been installed."
echo "To verify:"
echo "  sudo launchctl list | grep com.tailscale"
echo "  tailscale status"
echo "  tailscale netcheck"
echo ""
echo "If macOS blocks the binary, approve it in"
echo "System Settings > Privacy & Security, then re-run this installer."

if [ "${AUTO_UPDATE}" = "1" ] && [ -d "${EXTRACT_DIR}" ] && [ "${EXTRACT_DIR}" != "/tmp" ]; then
    echo "==> Cleaning up updater temp files..."
    rm -rf "${EXTRACT_DIR}"
fi
