# tailscale-macos-selfsigned

Self-signed **Tailscale** build for macOS Apple Silicon, mirroring the approach used for
[ZeroTierOne](https://github.com/Rahulsharma0810/ZeroTierOne).

This repo does **not** fork Tailscale. A GitHub Actions workflow clones upstream
[`tailscale/tailscale`](https://github.com/tailscale/tailscale) (latest release tag by
default, or a ref you choose), builds a **universal** (`arm64` + `amd64`) combined binary,
ad-hoc codesigns it, and publishes a stable `nightly` release. An installer script sets it
up as a macOS LaunchDaemon with a daily self-updater.

## Why

For internal/security use when the official signed package is blocked by MDM policy and you
need to run a locally-built, self-codesigned copy until the allow-list is updated.

## What gets built

- One combined binary built with Tailscale's `build_dist.sh --box` (`ts_include_cli` tag):
  invoked as `tailscaled` it's the daemon, invoked as `tailscale` it's the CLI — the same
  one-binary + symlink model as `zerotier-one`.
- `lipo`-merged universal binary, ad-hoc codesigned (`codesign --sign -`).
- Published as `tailscale-macos-universal.tar.gz` on the moving `nightly` tag.

## Install

```sh
curl -fSL -o tailscale-macos-universal.tar.gz \
  https://github.com/Rahulsharma0810/tailscale-macos-selfsigned/releases/download/nightly/tailscale-macos-universal.tar.gz
tar -xzf tailscale-macos-universal.tar.gz
sudo ./install-macos-selfsigned.sh
```

The installer:

- installs `tailscaled` to `/usr/local/bin` and symlinks `tailscale` to it,
- ad-hoc codesigns and strips quarantine,
- registers the LaunchDaemon (`tailscaled install-system-daemon`),
- runs `tailscale up` for interactive browser login,
- installs a root self-updater LaunchDaemon that pulls the latest `nightly` daily at 04:00.

## Verify

```sh
sudo launchctl list | grep com.tailscale
tailscale status
tailscale netcheck
```

## Build a specific upstream version

Run the **Build macOS Apple Silicon** workflow via *workflow_dispatch* and set
`tailscale_ref` to any branch, tag, or commit (empty = latest release tag).

## Notes

- No `.app` bundle: the open-source Tailscale daemon is CLI + LaunchDaemon only. The macOS
  menubar GUI is closed-source and can't be self-built.
- Ad-hoc signatures satisfy Gatekeeper-less execution after quarantine strip / user approval;
  they are not notarized.
