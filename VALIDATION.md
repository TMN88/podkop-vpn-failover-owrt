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

No physical reboot or LAN application/playback test was performed. Podkop is covered by local functional tests; the physical pilot used Forkozz. OpenWrt 25.12/apk installer behavior still needs hardware validation. Other firmware/backend versions require their own checks. No private client inventory, credentials or router backups are included.
