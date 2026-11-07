# Validation of 0.2.0

## Local checks

BusyBox ash syntax for shell files, `python3 tests/test_backend.py` with real jq 1.8.1, `node tests/test_view.js`, and git diff whitespace checks passed.

Backend tests cover Podkop/Forkozz selection, ambiguous/missing configuration, invalid/disabled/proxy sections, exact runtime outbound tag/binding, successful transitions, rollback, unverified rollback stopping a scan, external selection, bounded and escaped history, JSON serialization and log return status under set -e. View tests cover text rendering, empty history, refresh and refresh errors.

## Physical device

Xiaomi AX3000T, OpenWrt 24.10.5, Forkozz/NetShift 0.9.12:

- Installed the new worker, procd service, RPC and LuCI view.
- Confirmed actual tunnel transitions using native NetShift reload, UCI selection, sing-box binding and HTTPS checks.
- Confirmed rollback after an intentionally negative post-switch check.
- With production timings (120-second startup grace, 30-second interval, three failures), brought down the active AWG interface and observed automatic failover to a healthy reserve. Brought the original interface back up and restored it.
- Confirmed procd start/restart/stop and enable/disable, authenticated LuCI rendering, real operation history, JS HTTP 200 and anonymous RPC access denied.
- Confirmed protected network/DHCP/firewall/Tailscale config hashes and original NetShift config after restoring the initial tunnel.
- Fixed first-install UCI file creation; confirmed the UCI behavior in an isolated directory on the device. Added a wait for rpcd object registration after restart.

## Limits

No physical reboot or LAN application/playback test was performed. The physical failure/rollback pilot used Forkozz; physical Podkop failure injection remains unverified. OpenWrt 25.12/apk installation was exercised during the fleet rollout below; dependency download/install was not needed because curl/jq were already present. Other firmware/backend versions require their own checks. No private client inventory, credentials or router backups are included.

## Fleet installation on 2026-11-06

The published 0.2.0 payload was hash-verified and installed on 16 reachable client routers with configured AWG interfaces. Service running/autostart, RPC, journal and view HTTP 200 were checked after startup grace. Twelve monitored an active healthy AWG; three correctly stayed idle in proxy mode; one stayed idle because its routing backend was already stopped. Existing proxy selections and protected network/backend configurations were preserved. Four SSH-unreachable routers were not changed.

This exercised real Podkop and Forkozz installations on OpenWrt 24.10 (opkg) and 25.12 (apk). No mass failure injection, firmware/backend upgrades or router reboots were performed. GitHub push CI passed for the published payload. Client inventory and private logs are excluded.

## Unified page 0.2.1 (2026-11-07)

Local checks cover all six management/query buttons, asynchronous job handling, rejected operations, empty history, preserved collapse state, text safety and downloaded JSON generation. The real RPC action schema, invalid/malicious action rejection and separation of read/write permissions are tested.

On the existing physical Forkozz pilot, verified the unified page under Services, browser-triggered stop/start/restart and settings, actual tunnel checks, collapsible Russian operation history and an actual downloaded diagnostic JSON. The diagnostic file was parsed and validated. Anonymous management and arbitrary actions were denied. Protected network, DHCP, firewall, Tailscale and NetShift configurations remained unchanged. Service and autostart were restored to running/enabled.

The background runner uses setsid when present and otherwise a shell that ignores SIGHUP; no nohup dependency is required. Commands are limited to fixed executable paths and a fixed action whitelist with a timeout. No VPN keys, subscription URLs or complete router configurations are read for diagnostic downloads.
