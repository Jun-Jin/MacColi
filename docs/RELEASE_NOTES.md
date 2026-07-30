# Release Notes

All notable changes to MacColi, newest first. Each version is also published on
the [GitHub releases page](https://github.com/Jun-Jin/MacColi/releases) with the
notarized `.dmg`/`.zip` artifacts.

## v0.6.5

- 🚦 **Update check no longer trips GitHub's rate limit** — the latest version
  is read from the releases page's redirect instead of the REST API, whose
  60-requests/hour cap for unauthenticated clients could turn checks into an
  opaque "bad server response" error. Quiet launch checks also run at most
  once per day; manual checks in Settings are never throttled, and an
  unexpected response now reports the actual HTTP status.

## v0.6.4

- 🐚 **Workflow steps share one shell** — a run feeds all its steps through a
  single long-lived `zsh` login shell, so state a step sets — a variable, an
  `export`, a function, a `cd` — is still there for the next step:
  `RESULT=$(…)` in one step reads back as `$RESULT` in the next. Steps
  previously ran as independent `zsh -lc` processes that forgot everything
  between steps.
- 🔄 **Update check in Settings** — compares the running version against the
  latest GitHub release, with a quiet check at launch. Homebrew installs
  upgrade in place (`brew upgrade --cask maccoli`) with a one-click relaunch
  into the new version; other installs are pointed at the releases page.

## v0.6.3

- ↕️ **Reorder workflow steps** — every step row in the workflow editor has
  up/down buttons that swap it with its neighbor (disabled at the ends), so
  existing steps can be rearranged without re-typing them. Drag reordering
  rarely landed because the rows are covered by text fields; the buttons are
  the reliable way.

## v0.6.2

- 🙈 **Discard workflow output** — a per-workflow toggle drops step output
  instead of keeping it, for noisy routine workflows whose logs are never
  read. A failing step still keeps its tail (up to the last 512 lines) so the
  failure can be debugged, and an eye-slash marker on the workflow tile and
  the run sheet's step rows shows where output is being dropped. Chained
  workflows keep their own setting.
- ⚡ Step output rendering is decoupled from log rate — a chatty step repaints
  the run sheet at a steady rate instead of once per line, keeping the UI
  responsive under fast output.
- 🌐 A landing page for the project, published via GitHub Pages.

## v0.6.1

- 📦 **Workflow source files** — a workflow can list files (`~/.zshrc`, a
  project env file, …) that are sourced in order before each shell step, so
  functions and aliases defined there work in steps — plain `zsh -lc` loads
  login profiles but not `~/.zshrc`. The editor's file chooser shows dotfiles,
  and a chained workflow keeps its own list, like its working directory.
- 🖱️ Right-click blank space on the Workflows panel to create a workflow, and
  hover a tile for a pencil button that opens the editor.

## v0.6.0 — Workflows

- ⚡ **Workflows** — save shell-command sequences as one-click tiles on a new
  sidebar panel (or run them from the menu bar's **Run Workflow** submenu).
  Steps run in order with `zsh` in the workflow's working directory and the
  app's PATH/`DOCKER_HOST` environment, stopping at the first failure; the run
  sheet streams per-step output live and shows the running step's PID. Steps
  can chain other workflows (composition, with cycle detection), tiles section
  by an optional group, and the editor toggles each step between a one-line
  command and an expanded script area.
- 🗑️ The container log window gained a **clear** button — empties the view
  (docker's stored logs are kept; Reload restores them).

## v0.5.1

- 🔍 The list editor now has a **filter box** over the container checklist —
  substring, case-insensitive on name and image, matching the Containers and
  Images search. Makes large lists navigable when picking members.
- 🧹 Dropped the redundant sidebar **Rename…** menu; a list's name is edited in
  the same **Edit…** sheet as its membership.

## v0.5.0 — Custom container lists

- 🗂️ **Custom container lists** under the Containers sidebar item — create,
  rename, edit, and delete named groups of containers. Build one from the ＋
  button or from a multi-selection (**Add to List**). Each list reuses the full
  panel (All / Running / Stopped filter, ⌘F search, Select mode, bulk actions);
  membership is remembered by container name and persists across launches.
- 🧹 Inside a list, **Remove** offers *remove from this list* (detach) vs *delete
  container* (`docker rm`) — and deleting a container anywhere drops it from every
  list.
- 🖱️ Right-click a container row for its actions (Restart, View Logs, Open Shell,
  Remove) — the same menu as the ⋯ button.

## v0.4.5

- 🧹 Removed the legacy "Colimac" CA-certificate migration. Managed root CA
  provisioning now reads only the `maccoli-certs/` directory and `maccoli`
  YAML markers; certificates added under the old pre-rebrand build are no
  longer carried over and would need to be re-imported in Settings.

## v0.4.4

- 🐛 Fixed the Run Image sheet layout breaking when the selected image
  reference was long — the picker now truncates instead of overflowing.

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
