# podkop-vpn-failover-owrt

[Русский](README.md)

A maintained copy of [podkop-vpn-failover](https://github.com/SVTagan/podkop-vpn-failover), with an installer supporting OpenWrt 24.10 and 25.12.

This is an independent project and is not affiliated with Podkop developers. The upstream failover logic is retained: check real traffic over AmneziaWG interfaces and switch `podkop.main.interface` to a healthy reserve.

## Compatibility

- **OpenWrt 24.10.x** — `opkg` package manager.
- **OpenWrt 25.12.x** — `apk` package manager.
- Podkop must use VPN mode; AmneziaWG interfaces must be named `awg*`.
- Requires `uci`, procd, `curl`, `awk`, `sort`, `cut`, `sed`, `grep`, and `logger`.

The installer detects `apk` or `opkg` automatically and uses it for installed-package checks, index updates, and installing `curl` / optional `luci-app-commands`.

The first installation leaves the failover service stopped and disabled. Updates preserve the previous service and autostart state.

## Install

On the router, run:

```sh
uclient-fetch -q -O /tmp/pvf-install.sh https://raw.githubusercontent.com/TMN88/podkop-vpn-failover-owrt/main/install.sh && sh /tmp/pvf-install.sh
```

You can also download the installer using `curl` or `wget` and then run `sh /tmp/pvf-install.sh`.

To skip adding LuCI Custom Commands, set `INSTALL_LUCI_COMMANDS=0` before running the installer.

Check the VPN pool before enabling the service:

```sh
podkop-vpn-failover test
podkop-vpn-failover status
podkop-vpn-failover-control start
```

## CLI and logs

```sh
podkop-vpn-failover status
podkop-vpn-failover test
podkop-vpn-failover config
podkop-vpn-failover logs
logread | grep podkop-vpn-failover
```

When `luci-app-commands` is installed, actions are also available under LuCI → System → Custom Commands.

## Testing note

CI runs `sh -n` against the shell scripts. Actual live failover testing on routers running OpenWrt 25.12 is still required; package-manager compatibility alone does not claim that every router setup has been field-tested.

## Upstream and license

Copyright and attribution for the original project remain with the upstream authors. See [upstream](https://github.com/SVTagan/podkop-vpn-failover) and [LICENSE](LICENSE).
