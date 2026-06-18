# Release Notes

All notable changes to MacColi, newest first. Each version is also published on
the [GitHub releases page](https://github.com/Jun-Jin/MacColi/releases) with the
notarized `.dmg`/`.zip` artifacts.

## v0.4.3

- 🍶 New makgeolli PET-bottle app icon.
- 🔐 Migrated the legacy Colima CA-certificate provisioning into MacColi.
- 🚀 Self-contained release pipeline: every tag builds, signs, notarizes, and
  publishes automatically, then auto-bumps the Homebrew cask
  (`brew install --cask maccoli`).

## v0.4.2

- 🧭 Moved the VM monitor to the bottom of the sidebar.
- 🙈 Ignore signing/notarization credential files.

## v0.4.1 — Run containers & networks

- ▶️ **Run-container** sheet to create containers directly from an image.
- 🌐 **Networks** panel to manage Docker networks.

## v0.4.0 — Live monitoring

- 📊 Live CPU/memory monitoring in the Containers panel — a togglable,
  off-by-default opt-in.
- ⚠️ Single-row deletion now asks for confirmation across all resource panels.

## v0.3.2

- 💽 Shows per-volume disk usage and the container reference count.

## v0.3.1

- 🧹 **Clean Up** action runs a system prune.
- ✅ Fixed checkbox tap handling in Select mode.

## v0.3.0 — Bulk actions

- ☑️ Multi-select bulk actions across the resource panels — act on many
  containers, images, or volumes at once.

## v0.2.2

- 🚦 Flips status to *running* as soon as the VM is up and keeps resource
  readings stable.

## v0.2.1 — Logs & search

- 🔍 `⌘F` find/filter on the Containers, Images, and Volumes panels.
- 📜 Container logs open in a resizable window (click a row to view) that
  remembers its size.
- 📡 Opt-in live tail (`docker logs --follow`).
- ⎋ Close the log window with Escape.
- 🚦 Filter the containers list by run state.
- 🔋 Backs off polling when the dashboard window isn't frontmost.

## v0.2.0 — VM configuration & CA provisioning

- ⚙️ Reads config from `colima.yaml`, matching Colima's home resolution, with
  manual reload from disk.
- 🏠 Honors the login shell's `COLIMA_HOME` so the app targets the correct VM.
- 🌱 Seeds Settings from the live Colima VM on launch.
- 🧩 New start options: VM arch, VM type, Rosetta, mount type, hostname, network,
  DNS-host, SSH-agent, and Kubernetes.
- 🔐 Installs custom root CA certificates into the VM.
- 📦 Added `incus` to the container runtime options.

## v0.1.1

- 📥 Resilient image pulls: streams progress and retries transient daemon errors.
- © Sets the app copyright string.

## v0.1.0 — First release

- 🚀 Native macOS desktop app for Colima (v1 scaffold).
- 📦 In-app installer with robust tool detection.
- 🐚 **Open Shell** launches a real terminal.
- 🌋 App icon plus a reproducible icon generator.
- 🔏 Developer ID release pipeline: signing, notarization, and automated GitHub
  Releases.
