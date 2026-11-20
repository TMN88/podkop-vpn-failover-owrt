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
