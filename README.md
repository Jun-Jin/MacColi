<p align="center">
  <img src="MacColi/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" alt="MacColi app icon">
</p>

<h1 align="center">MacColi</h1>

A native macOS desktop app for [Colima](https://github.com/abiosoft/colima) — a
Docker Desktop-style GUI that wraps the `colima` and `docker` CLIs.

Lives in the menu bar with a full dashboard window:

- **VM lifecycle & settings** — start / stop / restart Colima, live status, and
  configure CPUs, memory, disk, and runtime (docker / containerd).
- **Containers** — list, start / stop / restart / remove, open a shell. Click a
  row to open its logs in a resizable window (its size is remembered) with an
  opt-in live tail (`docker logs --follow`).
- **Images** — list, pull, remove.
- **Volumes** — list, create, remove.

Every resource panel has a filter field — press **⌘F** to focus it and narrow
the list by name, image, status, and more.

## Requirements

- macOS 14 or later (Apple Silicon or Intel)
- [Colima](https://github.com/abiosoft/colima) and the Docker CLI:
  ```sh
  brew install colima docker
  ```
  (The app also offers an "Install Colima…" button that runs this for you.)

## Build & run

Open `MacColi.xcodeproj` in Xcode and run, or from the command line:

```sh
xcodebuild -scheme MacColi -configuration Debug -derivedDataPath ./.build/dd build
cp -R ./.build/dd/Build/Products/Debug/MacColi.app ./MacColi.app
open MacColi.app
```

`MacColi.app` at the repo root is the build product (git-ignored); refresh it
after each build so `open MacColi.app` runs the latest binary.

## Architecture

- **Swift 6 / SwiftUI**, Observation framework (`@Observable`).
- `MacColi/App` — `@main` app (`MenuBarExtra` + dashboard `Window`) and `AppState`,
  the `@MainActor @Observable` coordinator that owns all UI state.
- `MacColi/Services` — `ProcessRunner` (async subprocess execution),
  `CLI` (binary resolution + PATH/`DOCKER_HOST` setup), `ColimaService`,
  `DockerService` (which also opens an interactive shell via
  `open -a Terminal`), and `JSONLines`.
- `MacColi/Models` — Codable models decoded from `colima list --json` and
  `docker … --format '{{json .}}'`.
- `MacColi/Views` — dashboard, menu bar, and per-resource panels.

The app shells out to the CLIs rather than speaking the Docker Engine API
directly. Docker commands are routed through Colima's socket
(`~/.colima/default/docker.sock`) so they target the Colima VM regardless of the
active docker context.

The project uses a file-system–synchronized folder group, so new files added
under `MacColi/` are picked up automatically without editing `project.pbxproj`.

## Status

v1 scaffold. Manages the `default` Colima profile. Not sandboxed (it runs
subprocesses); ad-hoc signed for local development.
