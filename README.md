# Optimus

A native SwiftUI macOS utility for system statistics, battery history, storage inspection, per-process audio controls, and fan control.

## Build

The project targets macOS 26.4 or later. Open `Optimus/Optimus.xcodeproj` in a compatible Xcode and select the `Optimus` scheme. Configure signing locally before using background services.

To check compilation without signing or running the app:

```sh
xcodebuild -project Optimus/Optimus.xcodeproj -scheme Optimus \
  -configuration Release -derivedDataPath /tmp/optimus-build \
  CODE_SIGNING_ALLOWED=NO build
```

## Components

- `Optimus/Optimus`: app UI and feature services.
- `Optimus/OptimusCore`: probes, SQLite persistence, SMC bridge, and shared helper protocol.
- `Optimus/OptimusSampler`: one-shot battery and system sampler.
- `Optimus/OptimusFanHelper`: privileged fan-write helper.
- `Optimus/LaunchAgent` and `Optimus/LaunchDaemon`: service definitions embedded in the app.

Background sampling is opt-in through ServiceManagement. Once enabled, the sampler runs at login and every 60 seconds, including while the UI is closed. It writes local history to `~/.optimus_log.sqlite`, with SQLite WAL and SHM sidecars. History persists until explicitly deleted. The inspected source contains no network telemetry transport.

Fan control can register a privileged helper. Its current peer check compares the code-signing identifier; it does not enforce a trusted signing team. Treat this as experimental source, particularly for privileged fan control. Unsigned compilation does not validate service registration, audio permissions, or hardware behavior.

Generated builds, personal Xcode state, local telemetry, credentials, and the previous local Git metadata are excluded from this repository. See [CLEANUP.md](CLEANUP.md) for removal steps.
