# Reboot status and menu consistency — 2026-09-22

After the user's reboot, daemon PID 704 and menu PID 708 both started at login. The selected Audient was initially unavailable; the daemon waited for its UID and subsequently established the route. Fresh physical/virtual signal checks passed. Daemon underflow counter stayed at 6144 across the inspected steady-state period; dropped=0 and errors=0.

The installed `/Applications/MicBridge.app` was an older February build, while launchd started a standalone runtime menu executable. The menu item was an anonymous coloured dot. Updated the menu to a microphone symbol with a small colored status badge and accessible status description. Updated the installed app and the login installer to launch its executable. The previous app is backed up in the runtime backups directory. The daemon and driver were not restarted.

`run-menubar.sh` now starts the existing supervised app rather than spawning another standalone menu. Internal updater restart/rollback synchronizes the app executable with the selected runtime release before restarting its job.

The previous eight-hour monitor completed with 2780 snapshots, one daemon PID, and no reported stale/nonrunning/silent-output condition. However, 113 snapshots recorded counter increases: 166638 dropped frames and 454626 underflow frames. This is not a clean continuity pass; those events need further timing/load diagnosis if the user reports audible issues. The user declined manual hardware testing in the previous session.

The user could not recall whether the daemon label appeared in the Dock or the microphone privacy indicator. The exact UI symptom is therefore unconfirmed. macOS's microphone-use indicator is expected while bridging; it is separate from our status menu and should not be hidden.

The final menu omits a text label and uses a compact readable summary. Raw status and cumulative counters moved to scrollable diagnostics with copy and open-logs actions. The Swift validation gate now builds all products rather than repeating a single-product flag. Version 0.2.0 passed the full live gate (physical and virtual signal present), release packaging, and internal updater validation.
