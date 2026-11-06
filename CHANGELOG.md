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
