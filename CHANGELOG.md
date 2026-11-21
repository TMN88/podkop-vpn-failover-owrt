## 0.3.0-dev.5 (2026-11-21)

- Fix false RUNTIME_FATAL detection when NetShift reports a successful recovery.
- Preserve detection of genuine sing-box fatal errors.
- Publish a version-pinned OpenWrt installer and its SHA-256 checksum.

## 0.3.0-dev.4 (2026-11-20)

- Simplify LuCI to four primary controls and separate cards for bypass status, sing-box and the last check.
- Show individual results and timestamps for the active and reserve AmneziaWG tunnels.
- Report an unsuccessful manual check if any tunnel fails.

## 0.3.0-dev.3 (2026-11-20)

- Support stock OpenWrt without stat while preserving private-directory ownership checks.
- Return success after a valid endpoint-route preflight; clean owned routing resources with numeric protocol output.
- Verify the existing Clash API bound to a router-assigned IPv4 address, without creating listeners.
- Exclude only NetShift settings.shutdown_correctly from the user-configuration guard: native start/stop owns this lifecycle flag.
- Read the complete system log ring during native generation; distinguish lost log coverage from a fresh engine fatal error.
- Pass 48 local backend/recovery scenarios and the RPC, installer, CLI, UI, syntax and baseline checks.
- Validate one OpenWrt 25.12.5 / Forkozz 0.9.12 stand: stopped-engine recovery, reserve transition and rollback. See VALIDATION.md for injection method and limits.

## 0.3.0-dev.2 (2026-11-20)

- Wait for asynchronous Podkop/NetShift procd generation to finish and for the selected binding before engine checks or fallback start.
- Assign a distinct development version for updating clients to the bypass identity/status and real last-check UI.
- Recheck Forkozz auto selection with leftover Podkop configuration, the NetShift interface key and native reload/start targets.
- Keep router installation and real failover validation separate from local/CI results; no router changes or Tailscale actions performed.

## 0.3.0-dev (unreleased)

- 2026-11-19: dedicated current-bypass panel with Podkop/Forkop/Forkozz identity, native activity, engine state and verified-path status.
- Persist the actual completed active-tunnel probe timestamp/result independently from page refresh and reserve probes; mark missing/stale data and reject false green after a failed manual probe.
- Show the recorded bypass on every history row and command-output line; retain original job context across selection changes. Human-readable CLI status keeps JSON available through dashboard.

- Independent AWG checks continue while sing-box is stopped; recover a healthy current tunnel before replacing it.
- Explicit Podkop, Forkop (including owned interface children) and Forkozz/NetShift adapters, live backend detection and per-section reserve allowlist.
- Persistent maintenance pause, read-only status/dashboard, separate failure counters and monotonic cooldown/hold.
- Common operation lock, bounded child process groups, exact private routing cleanup and crash recovery manifests.
- Native backend generation/start, checked fallback engine start, live PID/config, stable runtime and fresh-fatal checks, section binding/policy/actual-engine HTTPS verification.
- Guarded field-only rollback; manual configuration changes abort writes. Never claim success from UCI/binding/AWG alone.
- LuCI pause/recovery controls, readable states and downloadable bounded diagnostics.
- Installer backup, numeric setting migration and preservation of stopped/running and boot states. No router deployment or hardware acceptance for this version yet.

## 0.2.1 (2026-11-07)

- Unified Services / VPN Failover page: service status, start/stop/restart, tunnel tests and current settings.
- Asynchronous commands with bounded execution time and command output on the page.
- Collapsible operation history, plain Russian explanations and expandable original diagnostics.
- Download diagnostic JSON without VPN keys or full router configurations.
- Separate read and management RPC permissions.

## 0.2.0 (2026-11-06)

- LuCI read-only operations journal with automatic refresh, timestamps, tunnel transitions and outcomes.
- Last 200 operations retained in RAM across service restarts; bounded JSON RPC response and authenticated ACL.
- Podkop / Forkozz (NetShift) backend selection, named section and custom runtime config path.
- Refuse ambiguous detection, disabled/proxy sections; verify rollback and runtime binding.
- Installer/uninstaller, documentation, BusyBox mock tests and view tests updated.
- Verified on Xiaomi AX3000T / OpenWrt 24.10.5 / Forkozz 0.9.12: installation, actual and automatic failover, rollback, procd and LuCI/RPC. Fixed UCI file creation and waited for rpcd registration.

# Changelog

## 0.1.4 - OpenWrt compatibility update

- Support both OpenWrt 24.10 (opkg) and 25.12 (apk) in the installer.
- Automatically detect the available package manager.
- Use manager-specific package status, index update, and package installation commands.
- Point downloaded runtime files to this repository.
- Update documentation and keep first-install safety behavior and upgrade state preservation.
