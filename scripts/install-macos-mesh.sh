#!/bin/bash
# Install the self-built "Retail" Tailscale-derived daemon on macOS.
# This is intended for internal/security use when the official signed
# package is blocked by MDM policy and you need to run a locally-built,
# self-codesigned copy until the allow-list is updated.
#
# Usage:
#   tar -xzf mesh-macos-universal.tar.gz
#   sudo ./install-macos-mesh.sh
#
# Auto-update (used by the updater LaunchDaemon):
#   sudo ./install-macos-mesh.sh --auto-update

set -euo pipefail

MESHD_BIN="/usr/local/bin/meshd"
MESH_BIN="/usr/local/bin/mesh"
SYS_PLIST="/Library/LaunchDaemons/com.mesh.meshd.plist"
SERVICE="com.mesh.meshd"
# Dedicated state dir + socket so this self-built daemon does NOT collide with
# the official closed-source Tailscale GUI app (io.tailscale.ipn.macsys), which
# uses /Library/Tailscale and its own NetworkExtension.
STATE_DIR="/Library/Mesh"
SOCKET="/var/run/mesh.socket"
GITHUB_REPO="Rahulsharma0810/tailscale-macos-selfsigned"

# `mesh` CLI needs --socket to talk to our daemon.
ts() { "${MESH_BIN}" --socket="${SOCKET}" "$@"; }

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
    # Jitter to avoid regular polling pattern
    sleep $((RANDOM % 300))
    echo "==> Checking for new release..."

    RELEASE_URL="https://github.com/${GITHUB_REPO}/releases/download/nightly/mesh-macos-universal.tar.gz"
    ETAG_FILE="${STATE_DIR}/installed.etag"

    # Check ETag via HEAD request (no download, no API rate limit).
    REMOTE_ETAG=$(curl -fsSLI --connect-timeout 30 --max-time 60 "${RELEASE_URL}" 2>/dev/null | grep -i '^etag:' | tr -d '\r' | sed 's/^[Ee][Tt][Aa][Gg]: *//')

    STORED_ETAG=""
    if [ -f "${ETAG_FILE}" ]; then
        STORED_ETAG=$(cat "${ETAG_FILE}" 2>/dev/null || true)
    fi

    if [ -n "${REMOTE_ETAG}" ] && [ "${REMOTE_ETAG}" = "${STORED_ETAG}" ]; then
        echo "==> Already up to date (${REMOTE_ETAG}); skipping."
        exit 0
    fi

    echo "==> New build available; fetching latest nightly release..."

    EXTRACT_DIR="/tmp/mesh-update-$$"
    rm -rf "${EXTRACT_DIR}"
    mkdir -p "${EXTRACT_DIR}"
    cd "${EXTRACT_DIR}"

    if ! curl -fSL --connect-timeout 30 --max-time 600 --retry 3 -o mesh-macos-universal.tar.gz "${RELEASE_URL}"; then
        echo "ERROR: failed to download nightly release from ${RELEASE_URL}" >&2
        rm -rf "${EXTRACT_DIR}"
        exit 1
    fi

    tar -xzf mesh-macos-universal.tar.gz
    BIN_SRC="${EXTRACT_DIR}/bin"

    # Keep a copy of the freshly-shipped installer so the daemon can self-update.
    if [ -f "${EXTRACT_DIR}/install-macos-mesh.sh" ]; then
        SCRIPT_SELF="${EXTRACT_DIR}/install-macos-mesh.sh"
    fi
    chmod +x "${SCRIPT_SELF}" 2>/dev/null || true
fi

if [ ! -f "${BIN_SRC}/meshd" ]; then
    echo "Cannot find '${BIN_SRC}/meshd'. Run this from the extracted tarball root." >&2
    exit 1
fi

if [ "$(id -u)" != "0" ]; then
    echo "This installer must run as root. Re-run with: sudo $0 ${*:-}" >&2
    exit 1
fi

echo "==> Installing meshd binary to ${MESHD_BIN}..."
mkdir -p /usr/local/bin
# Atomic-ish replace so a running daemon isn't corrupted mid-copy.
cp -f "${BIN_SRC}/meshd" "${MESHD_BIN}.tmp"
chmod 755 "${MESHD_BIN}.tmp"
mv -f "${MESHD_BIN}.tmp" "${MESHD_BIN}"

echo "==> Linking mesh CLI -> meshd..."
# The binary was built with --box (ts_include_cli): invoked as `mesh`
# it acts as the CLI, otherwise it runs the daemon.
ln -sf meshd "${MESH_BIN}"

echo "==> Self-codesigning the binary..."
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Self-Signed Mesh/ {print $2; exit}')
if [ -n "${IDENTITY}" ]; then
    codesign --force --sign "${IDENTITY}" --identifier com.mesh.meshd "${MESHD_BIN}"
else
    echo "No 'Self-Signed Mesh' identity found; using ad-hoc signature (-)." >&2
    codesign --force --sign - "${MESHD_BIN}"
fi

echo "==> Removing quarantine attributes..."
xattr -dr com.apple.quarantine "${MESHD_BIN}" 2>/dev/null || true

mkdir -p "${STATE_DIR}"

# NOTE: we deliberately do NOT use `meshd install-system-daemon`.
# On macOS that command first best-effort *uninstalls* (which does
# os.Remove(/usr/local/bin/meshd)) and then, because the running
# executable IS the target path, skips re-copying it (sameFile==true) --
# leaving no binary on disk. We write the launchd plist ourselves instead.
echo "==> Installing LaunchDaemon..."
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
        <string>${MESHD_BIN}</string>
        <string>--state=${STATE_DIR}/meshd.state</string>
        <string>--socket=${SOCKET}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
</dict>
</plist>
PLIST
chmod 644 "${SYS_PLIST}"
launchctl bootstrap system "${SYS_PLIST}" 2>/dev/null || \
    launchctl load -w "${SYS_PLIST}" 2>/dev/null || true

# Wait for the control socket to come up.
echo "==> Waiting for meshd to be ready..."
for i in $(seq 1 60); do
    if [ -S "${SOCKET}" ] && ts status >/dev/null 2>&1; then
        break
    fi
    # `status` exits non-zero when logged out too; treat those as "ready".
    if ts status 2>&1 | grep -qiE 'logged out|stopped|NeedsLogin'; then
        break
    fi
    sleep 1
done

# Bring the node up with interactive browser login (unless already logged in).
if ts status 2>/dev/null | grep -qiv 'logged out' && ts status >/dev/null 2>&1; then
    echo "==> Already logged in; skipping 'mesh up'."
elif [ "${AUTO_UPDATE}" = "1" ]; then
    echo "==> Auto-update: not logged in or daemon not ready; skipping interactive 'mesh up'."
else
    echo "==> Bringing Mesh up (interactive browser login)..."
    echo "    A login URL will be printed below. Open it in a browser to authenticate."
    ts up || {
        echo "'mesh up' did not complete. You can retry manually with:"
        echo "  sudo mesh --socket=${SOCKET} up"
    }
fi

# ---- Self-updater LaunchDaemon (root-owned, polls every 15 min) ----
echo "==> Installing self-updater LaunchDaemon..."
UPDATER_SCRIPT="${STATE_DIR}/mesh-update.sh"
if [ "${SCRIPT_SELF}" != "${UPDATER_SCRIPT}" ]; then
    cp -f "${SCRIPT_SELF}" "${UPDATER_SCRIPT}"
    chown root:wheel "${UPDATER_SCRIPT}"
    chmod 755 "${UPDATER_SCRIPT}"
fi

UPDATER_PLIST="/Library/LaunchDaemons/com.mesh.meshd.updater.plist"
launchctl bootout system "${UPDATER_PLIST}" 2>/dev/null || true
tee "${UPDATER_PLIST}" >/dev/null <<UPDATER
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.mesh.meshd.updater</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${UPDATER_SCRIPT}</string>
        <string>--auto-update</string>
    </array>
    <key>StartInterval</key>
    <integer>900</integer>
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

launchctl list | grep -q "com.mesh.meshd.updater" \
    && echo "Updater LaunchDaemon loaded." \
    || echo "Updater LaunchDaemon will load on next boot."

echo ""
echo "Mesh (self-built) has been installed."
echo "This daemon uses a dedicated socket so it does NOT clash with the"
echo "official Tailscale GUI app. Talk to it with --socket:"
echo "  sudo launchctl list | grep com.mesh"
echo "  sudo mesh --socket=${SOCKET} status"
echo "  sudo mesh --socket=${SOCKET} netcheck"
echo ""
echo "Tip: add a shell alias -> alias msh='sudo mesh --socket=${SOCKET}'"
echo ""
echo "If macOS blocks the binary, approve it in"
echo "System Settings > Privacy & Security, then re-run this installer."

if [ "${AUTO_UPDATE}" = "1" ] && [ -n "${REMOTE_ETAG:-}" ]; then
    mkdir -p "${STATE_DIR}"
    echo "${REMOTE_ETAG}" > "${STATE_DIR}/installed.etag"
fi

if [ "${AUTO_UPDATE}" = "1" ] && [ -d "${EXTRACT_DIR}" ] && [ "${EXTRACT_DIR}" != "/tmp" ]; then
    echo "==> Cleaning up updater temp files..."
    rm -rf "${EXTRACT_DIR}"
fi
