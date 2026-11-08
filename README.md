# tailscale-macos-selfsigned (Mesh build)

Self-built, rebranded **Mesh** daemon for macOS Apple Silicon, derived from upstream
[Tailscale](https://github.com/tailscale/tailscale) and mirroring the approach used for
[ZeroTierOne](https://github.com/Rahulsharma0810/ZeroTierOne).

This repo does **not** fork Tailscale. A GitHub Actions workflow clones upstream
[`tailscale/tailscale`](https://github.com/tailscale/tailscale) (latest release tag by
default, or a ref you choose), builds a **universal** (`arm64` + `amd64`) combined binary,
renames it to `mesh`/`meshd`, ad-hoc codesigns it, and publishes a stable `nightly`
release. An installer script sets it up as a macOS LaunchDaemon with a daily self-updater.

## Why

For internal/security use when the official signed package is blocked by MDM policy and you
need to run a locally-built, self-codesigned copy until the allow-list is updated. The build
is rebranded to "Mesh" so it does not collide with an installed official Tailscale.app.

## What gets built

- One combined binary built with Tailscale's `build_dist.sh --box` (`ts_include_cli` tag):
  invoked as `mesh` it's the CLI, invoked as `meshd` it's the daemon — the same
  one-binary + symlink model as `zerotier-one`.
- `lipo`-merged universal binary, ad-hoc codesigned (`codesign --sign -`).
- Published as `mesh-macos-universal.tar.gz` on the moving `nightly` tag.

## Install

```sh
curl -fSL -o mesh-macos-universal.tar.gz \
  https://github.com/Rahulsharma0810/tailscale-macos-selfsigned/releases/download/nightly/mesh-macos-universal.tar.gz
tar -xzf mesh-macos-universal.tar.gz
sudo ./install-macos-mesh.sh
```

The installer:

- installs `meshd` to `/usr/local/bin` and symlinks `mesh` to it,
- ad-hoc codesigns and strips quarantine,
- registers the LaunchDaemon (`com.mesh.meshd`),
- runs `mesh up` for interactive browser login,
- installs a root self-updater LaunchDaemon that polls GitHub every 15 minutes and
  installs a new build as soon as one is published.

## Verify

This daemon runs on a **dedicated socket** so it never collides with the official
closed-source Tailscale GUI app (`io.tailscale.ipn.macsys`, which uses `/Library/Tailscale`).
Talk to it with `--socket`:

```sh
sudo launchctl list | grep com.mesh
sudo mesh --socket=/var/run/mesh.socket status
sudo mesh --socket=/var/run/mesh.socket netcheck
# convenience:
alias msh='sudo mesh --socket=/var/run/mesh.socket'
```

State lives in `/Library/Mesh`.

## Build a specific upstream version

Run the **Build macOS Apple Silicon** workflow via *workflow_dispatch* and set
`tailscale_ref` to any branch, tag, or commit (empty = latest release tag).

## Notes

- No `.app` bundle: the open-source Tailscale daemon is CLI + LaunchDaemon only. The macOS
  menubar GUI is closed-source and can't be self-built.
- Ad-hoc signatures satisfy Gatekeeper-less execution after quarantine strip / user approval;
  they are not notarized.
- The upstream Tailscale code is not string-rewritten; only the binary name, socket, state
  dir, and LaunchDaemon labels are rebranded. Version/help output still repomsh "tailscale".
- The workflow runs daily at 02:00 UTC so new upstream Tailscale releases are picked up
  automatically; the installed client polls every 15 minutes and updates as soon as a new
  build is published (skipping redundant installs via a digest check).
