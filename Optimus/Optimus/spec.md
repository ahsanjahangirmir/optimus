# macOS Unified System Dashboard — Technical Specification

**Platform:** macOS only (Tahoe 26.x+), universal binary — Intel + Apple Silicon
**Stack:** Native Swift / SwiftUI
**Status:** Ready for implementation

---

## 1. Vision

A single native dashboard app replacing the need for CleanMyMac, Macs Fan Control, iStat Menus, SoundSource, and Activity Monitor — built around one core principle: **classify, never auto-delete.** Every destructive action requires explicit user review and confirmation. The app should look and feel like a first-party Apple utility, not a third-party skin.

Modules:
1. Storage Survey & Cleanup (filesystem + Chrome browser storage)
2. Battery Monitoring
3. Sound Control
4. Fan Control & Sensors
5. CPU / RAM / SSD Live Dashboard
6. Claude Code Data Management

---

## 2. Architecture Overview

- **Single native Swift/SwiftUI app.** No Electron/Tauri, no browser extension required (Chrome-only scope allows direct on-disk reading of Chrome's profile data instead of a WebExtension bridge).
- **Two privilege tiers:**
  - Main app process — runs as the user, handles all reads (SMC sensors, IOKit, Core Audio, filesystem metadata, Chrome profile files).
  - A privileged helper daemon, installed once via `SMJobBless`, used **only** for the one operation that requires root: writing fan speed targets to the SMC. All other functionality needs no elevated privileges.
- **Local storage:** SQLite (via GRDB or plain `sqlite3`) for scan history, rollback logs, and size-trend snapshots over time.
- **No cloud dependency.** Everything runs and stays local.

---

## 3. Module: Storage Survey & Cleanup

### 3.1 Scope of survey
- **OS-level:** cache directories (`~/Library/Caches`, `/private/var/folders` temp), log files, orphaned Application Support data (apps no longer in `/Applications`), package manager caches (`~/.npm`, `~/Library/Caches/pip`, Homebrew cache).
- **Chrome browser storage** (Chrome only, all profiles, auto-detected via `~/Library/Application Support/Google/Chrome/Local State`):
  - **IndexedDB** — per-origin, straightforward: each origin has its own folder under `<Profile>/IndexedDB/`; size = directory size, no parsing needed.
  - **Local Storage** — v1: profile-level total only (it's one shared LevelDB database per profile, not split per origin — parsing key prefixes for a per-origin breakdown is a stretch goal, not v1).
  - **HTTP Cache** — profile-level total only (Chrome's "Simple Cache" is a hash-keyed blob store, not per-origin).

### 3.2 Classification model
Two tiers only — no silent third "safe, will auto-delete" tier for anything derived from browser storage:

| Bucket | Applies to | Criteria |
|---|---|---|
| **Auto-safe (high confidence)** | OS cache dirs, orphaned app data, package manager caches | Path matches an OS-sanctioned ephemeral-cache convention, or owning app confirmed uninstalled |
| **Review required** | All Chrome storage items, ambiguous filesystem items | No OS-level "safe to lose" guarantee exists for this data |

### 3.3 Per-item fields shown in review UI

**Filesystem items:**
- Path, size, file count, last-accessed, last-modified, owning app + installed/uninstalled status, rule matched.

**Chrome origin items:**
- Domain, profile, storage type, size, **last visited** vs **last write** (shown separately — divergence signals a background sync/service worker), **`navigator.storage.persisted()` flag** (if persisted → default recommendation is "keep"), installed-PWA status, size trend if a prior scan exists.

### 3.4 Deletion actions
Two explicit, separate actions per item or batch:
- **Move to Trash** — calls `FileManager.trashItem(at:)`; default/recommended action; recoverable via Finder.
- **Permanently Delete** — raw unlink; only offered as a distinct, separately-confirmed action, never the default.
- **Rollback log** (SQLite) — every deletion (either type) logs path, size, timestamp, and action type before it executes.
- **Locked/in-use file handling** — before deleting Chrome-related files, check whether Chrome is running (and warn/block); catch and surface unlink failures rather than forcing them.

### 3.5 Report export (for AI-agent review)
Markdown, one summary header + one table per category. No content redaction needed (per Ahsan's call) — optimize for richness over minimalism. Include a `Row ID` per line so agent suggestions map back to the review UI unambiguously. Schema:

```markdown
# Storage Survey — <timestamp>

**Total reclaimable (estimate): X GB**
- <category>: <size>
- ...

## <Category Name>
| Row ID | Path/Origin | Size | Last Accessed | Last Modified | Rule Matched | ... |
```
(Exact columns per category as defined in 3.3.)

### 3.6 Performance
- Use `stat`-only metadata reads wherever content isn't needed.
- Cache scan results keyed by directory mtime; re-scan only changed subtrees.
- Parallelize independent trees (separate app cache dirs, separate Chrome profiles) — I/O-bound, safe to parallelize.
- Optional v2: FSEvents-based live index instead of on-demand full walks.
- **Progress must be real, not cosmetic:** emit per-phase, per-directory progress events (e.g. "scanning ~/Library/Caches, 340 of ~1200 folders") so the UI reflects actual scan state, not a generic spinner.

---

## 4. Module: Battery Monitoring

- **Source:** IOKit — `IOServiceGetMatchingService` on `AppleSmartBattery`, plus `IOPSCopyPowerSourcesInfo` for live charge state.
- **Data shown:** cycle count, design capacity vs. current max capacity (health %), condition, temperature, voltage, amperage, time to full/empty.
- **No special entitlement required** for reads.

---

## 5. Module: Sound Control

Built on the **Core Audio Process Tap API** (macOS 14.2+): `AudioHardwareCreateProcessTap` + `CATapDescription`. No kernel extension, no virtual driver.

### 5.1 Live per-app metering
- Enumerate active audio processes via `kAudioHardwarePropertyProcessObjectList`.
- Tap each process, read levels in the IOProc callback for real-time meters.

### 5.2 Per-app volume / mute / boost
- Tap with `.mutedWhenTapped` — original output is silenced, audio is routed through the tap, gain/mute applied in the callback, then forwarded to the real output device.
- Reference implementation to study before building from scratch: **Mimir** (open source, GitHub — `ThalesBMC/Mimir`), a Swift per-app volume mixer using this exact technique.

### 5.3 Per-app output device routing (e.g. Spotify → speakers, Zoom → AirPods, simultaneously)
- Same tap primitive, each app's captured stream forwarded to a different physical output device via its own aggregate device / IOProc pair.
- Harder than 5.1/5.2 — budget more build time here.

### 5.4 AirPods A2DP-preserving auto-toggle (new feature)
**Problem:** Bluetooth AirPods run one active profile at a time. The moment any app requests the AirPods microphone (e.g. joining a Zoom call), the whole Bluetooth link drops from high-quality A2DP to low-quality HFP — degrading audio for every app using AirPods output (e.g. simultaneous Spotify playback), not just the calling app.

**Design (toggle, default off):**
1. Watch `kAudioProcessPropertyIsRunningInput` per audio process object to detect the moment an app actually starts pulling mic input (not just "app is open").
2. When `IsRunningInput` goes true **and** the current default input device is AirPods → set `kAudioHardwarePropertyDefaultInputDevice` to the built-in microphone via `AudioObjectSetPropertyData`.
3. When `IsRunningInput` goes false again (call ends) → switch default input back to AirPods.
4. UI must be explicit that this is a **system-wide default-input swap**, not true per-app input routing (macOS has no concept of two apps using two different input devices simultaneously) — show a visible "using built-in mic while call is active" indicator.
5. **Known bug to design around:** `kAudioDevicePropertyDeviceIsRunningSomewhere` does not reliably report Bluetooth input devices as active (documented, open Apple Developer Forums issue) — do not use it for this detection. Use the process-side `IsRunningInput` property instead.
6. Fallback: if detection fails or the target app exposes its own input-device setting, surface a manual notification rather than silently doing nothing.

---

## 6. Module: Fan Control & Sensors

- **Reads (temps, fan RPM):** unprivileged SMC key queries — no permission prompt needed.
- **Writes (fan speed targets):** require root — implemented via a privileged helper daemon installed once through `SMJobBless` (same pattern as Macs Fan Control / smcFanControl), not a setuid binary or sudoers rule.
- **⚠️ Required UI disclaimer (Apple Silicon):** On several Apple Silicon models, manual fan override only takes effect once macOS itself has already decided cooling is needed (typically ~60–70°C) — before that threshold, requested fan speeds are ignored and fans stay off regardless of user input. Even where control works, it can generally only **raise** fan speed above the firmware's own curve, never lower it below Apple's floor. This is a hardware/firmware restriction outside the app's control, not a bug — the dashboard must say so explicitly on the fan control screen so it isn't mistaken for broken functionality.
- **Sensors displayed:** CPU, GPU, SSD, memory controller, battery temperature sensors — SMC key names vary by Mac model, so maintain a per-model sensor key table (same approach every existing tool in this space uses).

---

## 7. Module: CPU / RAM / SSD Live Dashboard

- **CPU:** `host_statistics` / `host_processor_info` (Mach APIs), system-wide + per-core.
- **RAM:** `vm_statistics64` for system-wide memory pressure/usage.
- **Per-process attribution:** `libproc` / `proc_pidinfo` for per-process CPU% and RSS memory.
- **Disk:** `statfs` for volume-level usage.
- **Reference (for architecture/UX ideas, not to copy UI):** exelban/Stats (open source, MIT) implements this data layer already — worth reading for the plumbing, but the explicit design goal here is a **cleaner, less cognitively-overloading information architecture** than Stats provides. Prioritize a small number of clearly-labeled top-level views over dense simultaneous readouts.

---

## 8. Module: Claude Code Data Management

**No custom auto-classification logic** — this module is monitoring + manual cleanup only, deferring to Claude Code's own built-in safety mechanism wherever possible.

### 8.1 Monitoring
Show live size for each folder under `~/.claude/`:
- `projects/`, `tasks/`, `debug/`, `file-history/`, `history.jsonl` — per-project, session-scoped data.
- `cache/`, `paste-cache/`, `telemetry/` — pure ephemeral cache, safe to clear freely.
- `shell-snapshots/`, `backups/` — **not** project-scoped; Claude Code's own purge command deliberately skips these — surface them separately with a manual-only clear action.
- `~/.claude.json`, `~/.claude/settings.json`, `~/.claude/plugins/` — **never offer to delete these.** They hold auth, preferences, and installed plugins.
- `sessions/`, `session-env/`, `ide/`, `chrome/`, `skills/` — lower-confidence purpose (plausibly session state, IDE/Chrome integration state, installed skills); confirm exact role against current Claude Code docs before deciding how to display or offer cleanup for these — do not guess.

### 8.2 Cleanup actions
- **Preferred path:** shell out to `claude project purge <path> --dry-run` to preview, then `claude project purge <path>` for confirmed per-project cleanup — reuses Anthropic's own maintained deletion logic rather than reimplementing it.
- **Surface, don't auto-tune:** expose the `cleanupPeriodDays` setting from `settings.json` in the UI as a visible/editable control, since it governs automatic transcript retention going forward.
- Manual clear action for `shell-snapshots/` and `backups/`, clearly labeled as not covered by the official purge command.

---

## 9. Security & Permissions Model

- **Full Disk Access** required for filesystem survey (OS caches, Chrome profile reads) and SMC reads — one-time macOS permission prompt.
- **Microphone/audio capture entitlement** (`NSAudioCaptureUsageDescription`) required for Core Audio Process Tap usage — triggers a system permission prompt on first tap.
- **Root access** is scoped to exactly one operation (SMC fan-speed writes) via the SMJobBless helper — the rest of the app never needs elevated privileges.
- **Personal build, not distributed:** since this runs only on Ahsan's own machine, standard `cargo`-equivalent local Swift builds won't carry the `com.apple.quarantine` flag that triggers Gatekeeper, so no Developer ID signing/notarization is required. If the flag is ever present (e.g. after zipping/unzipping the build), `xattr -d com.apple.quarantine <App>.app` clears it. Notarization only becomes necessary if the app is ever distributed to someone else.

---

## 10. Known Limitations (by design, not oversights)

- Chrome Local Storage and HTTP Cache are reported at profile granularity in v1, not per-origin (technical constraint of their on-disk format — see 3.1).
- Fan control cannot override macOS's own thermal curve on several Apple Silicon models (see §6).
- The AirPods toggle solves the Zoom/Spotify quality issue via a system-wide default-input swap, not literal simultaneous per-app input routing — that capability doesn't exist in macOS.
- Chrome is migrating IndexedDB's on-disk format from LevelDB toward SQLite (currently limited to in-memory/Incognito contexts as of this writing) — re-verify the parsing target if/when this ships for persistent storage.
- Safari and Firefox are explicitly out of scope (Chrome-only, per current usage).

---

## 11. Suggested Build Order

1. **Foundation:** SwiftUI shell, dashboard navigation, SQLite setup.
2. **Battery module** — simplest, fully self-contained, good first working feature.
3. **CPU/RAM/SSD dashboard** — establishes the live-monitoring UI pattern reused elsewhere.
4. **Storage survey (filesystem only first)** — classification model, review UI, Trash/Permanent-delete + rollback log, report export.
5. **Chrome storage survey** — layer onto the storage module once the filesystem path is solid.
6. **Claude Code module** — monitoring + `project purge` integration.
7. **Fan control** — SMC reads first (no privilege needed), then the SMJobBless helper for writes.
8. **Sound control** — metering first, then per-app volume/mute, then per-app output routing, then the AirPods toggle last (most detection-dependent, build once the rest of the Core Audio plumbing is proven).
