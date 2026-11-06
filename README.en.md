# VPN Failover for Podkop and Forkozz

Version 0.2.0, tested on a physical Xiaomi AX3000T (OpenWrt 24.10.5, Forkozz/NetShift 0.9.12). See [Russian instructions](README.md).

Supports OpenWrt opkg/apk, existing AmneziaWG `awg*` interfaces and one named VPN section in Podkop or Forkozz/NetShift. Configure `/etc/config/vpn_failover`: `config settings 'main'`, `option backend 'auto'` (or `podkop` / `forkozz`), `option section 'main'`. Restart failover after configuration changes. Auto detection refuses ambiguity. Proxy/subscription nodes are outside this interface failover workflow.

LuCI → Services → VPN Failover shows the latest 200 operations: timestamp, backend/section, source/destination, outcome, diagnostics. Read-only authenticated RPC, refresh every 5 seconds. History survives service restarts, is held in RAM and disappears on router reboot. CLI: `podkop-vpn-failover history`, JSON: `podkop-vpn-failover dashboard`.

Uses the selected package's UCI `interface` field, its native reload and `${section}-out` runtime binding check. Forkozz uses `/usr/bin/netshift reload` and honors `netshift.settings.config_path`. The selected section must be enabled and in VPN mode. Other configuration is preserved; backend reload can interrupt other sections' connections. HTTPS checks validate interface egress, not actual LAN application playback. Failed transitions attempt verified rollback; unverified rollback stops the current scan.

Installer downloads worker, control/init, RPC, view, menu and ACL, installs curl/jq if missing, optionally luci-app-commands, refreshes rpcd and preserves existing failover enabled/running state. Initial installation stays stopped/disabled. Requires LuCI/rpcd for the journal page.

Validation: `python3 tests/test_backend.py`, `node tests/test_view.js`, and `sh -n` on shell files. Mock tests cover backend selection, actual jq binding checks, failover, rollback, external changes, disabled/proxy guards and bounded/escaped JSON history. Physical Forkozz installation, procd start/restart/stop, automatic failover after real active-interface shutdown, verified rollback, authenticated LuCI rendering and denied anonymous RPC were tested. Reboot, physical Podkop failure injection and LAN application traffic remain unverified. Installation and normal monitoring on Podkop/Forkozz were also checked during the fleet rollout; see VALIDATION.md.

Original authors and MIT license are preserved. [Original project](https://github.com/SVTagan/podkop-vpn-failover).
