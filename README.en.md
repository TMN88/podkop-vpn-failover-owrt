# VPN Failover for Podkop and Forkozz

Version 0.2.1 adds a unified LuCI Services → VPN Failover page: service status, start/stop/restart, live status, tunnel checks, current settings, collapsible operation history with Russian explanations, and downloadable diagnostic JSON.

Commands run asynchronously with a fixed action whitelist, a single-job lock and a 180-second execution limit. Management uses the write ACL; status/job/diagnostics use read ACL. The UI displays command output and preserves the expanded history/details during automatic refresh. Download contains original events, service state, failover parameters and last command output; it does not read VPN credentials or full router configurations.

Start also enables autostart; stop disables it; restart preserves its enabled state. Tunnel checks do not switch routing. Installation/update preserves the existing service and configuration state.

See [Russian instructions](README.md) and [validation](VALIDATION.md). AmneziaWG `awg*` interfaces, one named Podkop or Forkozz/NetShift VPN section, OpenWrt 24.10/opkg and 25.12/apk are supported. History holds 200 operations in RAM and is cleared on reboot. Original authors and MIT license are preserved.
