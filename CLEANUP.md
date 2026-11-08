# Removing Optimus from a Mac

Keep the source repository if you want an archive. Removing runtime data does not require deleting the source or stripping the service definitions from the Xcode project.

## Stop services before deleting the app

If Optimus is installed and active:

1. Return any manually controlled fans to automatic mode in the app.
2. Turn off background collection in Telemetry. This calls `SMAppService.unregister()` for `com.ajm.Optimus.Sampler`.
3. Disable Optimus under System Settings > General > Login Items & Extensions, including its background item. The current fan-helper UI does not expose an unregister action.
4. Quit Optimus. Verify the service labels below. An administrator may need to unload an installed root fan helper before removal.

```sh
pgrep -x Optimus
pgrep -x OptimusSampler
pgrep -x OptimusFanHelper
launchctl print "gui/$(id -u)/com.ajm.Optimus.Sampler"
launchctl print system/com.ajm.Optimus.FanHelper
```

No PID output means no matching executable was found. A service-not-found response means that label is absent from that launchd domain. Do not kill unrelated system processes or reset the entire background-item database.

## Reset permissions and remove runtime files

Run as the affected user after stopping the app and helpers:

```sh
tccutil reset All com.ajm.Optimus
defaults delete com.ajm.Optimus
rm -f "$HOME/.optimus_log.sqlite" \
  "$HOME/.optimus_log.sqlite-wal" \
  "$HOME/.optimus_log.sqlite-shm"
```

Deleting the database erases telemetry, scan history, and deletion logs. A missing preferences-domain message is harmless if the preferences were already removed.

Open System Settings > Privacy & Security > Full Disk Access and remove any remaining Optimus entry with the minus button. Inspect Microphone and System Audio Recording for remaining entries. The permission reset above clears approval status; it does not prove every Settings list entry has disappeared. Do not grant Terminal or an agent Full Disk Access merely to inspect the privacy database.

Delete the installed `Optimus.app` if present. Remove only confirmed Optimus build directories and Xcode `xcuserdata` directories. Inspect `~/Library/Developer/Xcode/DerivedData` for project-specific output before deleting individual directories. Avoid wildcard deletion of shared caches, LaunchAgents, or LaunchDaemons.

Recheck processes and launch services after removal. An unused registration may remain visible in Login Items even when its executable and launch service are absent; remove or disable that specific item in Settings. `sfltool dumpbtm` is not required for this cleanup and can trigger administrator authentication.
