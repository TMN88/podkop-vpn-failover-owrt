#!/bin/sh

set -u

TAG="podkop-vpn-failover"
BASE_URL="${PVF_BASE_URL:-https://raw.githubusercontent.com/TMN88/podkop-vpn-failover-owrt/main}"
WORKER_DST="/usr/bin/podkop-vpn-failover"
CONTROL_DST="/usr/bin/podkop-vpn-failover-control"
INIT_DST="/etc/init.d/podkop-vpn-failover"
INSTALL_LUCI_COMMANDS="${INSTALL_LUCI_COMMANDS:-1}"
PKG_MANAGER=""

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || fail "Run this installer as root."
[ -r /etc/openwrt_release ] || fail "This installer is intended for OpenWrt."
command -v uci >/dev/null 2>&1 || fail "uci is required."

# OpenWrt 24.10 uses opkg; OpenWrt 25.12 uses apk.
if command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
elif command -v opkg >/dev/null 2>&1; then
    PKG_MANAGER="opkg"
else
    fail "Neither apk nor opkg was found; unsupported OpenWrt package manager."
fi
info "Detected package manager: ${PKG_MANAGER}"

fetch() {
    url="$1"; dst="$2"
    if command -v curl >/dev/null 2>&1; then curl -fsSL "$url" -o "$dst"; return $?; fi
    if command -v uclient-fetch >/dev/null 2>&1; then uclient-fetch -q -O "$dst" "$url"; return $?; fi
    if command -v wget >/dev/null 2>&1; then wget -q -O "$dst" "$url"; return $?; fi
    return 127
}

pkg_installed() {
    package="$1"
    if [ "$PKG_MANAGER" = "apk" ]; then
        apk info -e "$package" >/dev/null 2>&1
    else
        opkg status "$package" 2>/dev/null | grep -q '^Status: install .* installed$'
    fi
}

pkg_update() {
    if [ "$PKG_MANAGER" = "apk" ]; then apk update; else opkg update; fi
}

pkg_install() {
    if [ "$PKG_MANAGER" = "apk" ]; then apk add "$1"; else opkg install "$1"; fi
}

need_update=0
pkg_installed curl || need_update=1
if [ "$INSTALL_LUCI_COMMANDS" = "1" ] && ! pkg_installed luci-app-commands; then need_update=1; fi
if [ "$need_update" -eq 1 ]; then
    info "Updating package indexes (${PKG_MANAGER})..."
    if ! pkg_update; then warn "Package index update reported errors; continuing with available indexes."; fi
fi

if ! pkg_installed curl; then
    info "Installing curl..."
    pkg_install curl || fail "curl installation failed."
fi

for cmd in logger awk sort cut sed grep; do
    command -v "$cmd" >/dev/null 2>&1 || fail "$cmd is required."
done

if ! command -v podkop >/dev/null 2>&1 && [ ! -x /usr/bin/podkop ]; then fail "Podkop is not installed."; fi
[ -x /etc/init.d/podkop ] || fail "Podkop init service was not found at /etc/init.d/podkop."

connection_type="$(uci -q get podkop.main.connection_type 2>/dev/null)"
if [ "$connection_type" != "vpn" ]; then
    warn "podkop.main.connection_type is '${connection_type:-unset}', not 'vpn'. The failover daemon will stay idle until Podkop main uses VPN mode."
fi

TMP_WORKER="/tmp/${TAG}.worker.$$"
TMP_CONTROL="/tmp/${TAG}.control.$$"
TMP_INIT="/tmp/${TAG}.init.$$"
trap 'rm -f "$TMP_WORKER" "$TMP_CONTROL" "$TMP_INIT"' EXIT INT TERM

info "Downloading worker..."
fetch "${BASE_URL}/podkop-vpn-failover" "$TMP_WORKER" || fail "Failed to download worker from ${BASE_URL}."
info "Downloading service control wrapper..."
fetch "${BASE_URL}/podkop-vpn-failover-control" "$TMP_CONTROL" || fail "Failed to download control wrapper from ${BASE_URL}."
info "Downloading procd init script..."
fetch "${BASE_URL}/podkop-vpn-failover.init" "$TMP_INIT" || fail "Failed to download init script from ${BASE_URL}."

[ -s "$TMP_WORKER" ] || fail "Downloaded worker is empty."
[ -s "$TMP_CONTROL" ] || fail "Downloaded control wrapper is empty."
[ -s "$TMP_INIT" ] || fail "Downloaded init script is empty."
/bin/sh -n "$TMP_WORKER" || fail "Downloaded worker failed shell syntax validation."
/bin/sh -n "$TMP_CONTROL" || fail "Downloaded control wrapper failed shell syntax validation."
/bin/sh -n "$TMP_INIT" || fail "Downloaded init script failed shell syntax validation."
grep -q '^# podkop-vpn-failover$' "$TMP_WORKER" || fail "Downloaded worker does not look like podkop-vpn-failover."

existing_install=0
was_running=0
was_enabled=0
if [ -x "$INIT_DST" ]; then
    existing_install=1
    "$INIT_DST" running >/dev/null 2>&1 && was_running=1
    "$INIT_DST" enabled >/dev/null 2>&1 && was_enabled=1
    info "Stopping existing failover service before update..."
    "$INIT_DST" stop >/dev/null 2>&1 || true
fi

cp "$TMP_WORKER" "$WORKER_DST" || fail "Failed to copy ${WORKER_DST}."
chmod 0755 "$WORKER_DST" || fail "Failed to set permissions on ${WORKER_DST}."
cp "$TMP_CONTROL" "$CONTROL_DST" || fail "Failed to copy ${CONTROL_DST}."
chmod 0755 "$CONTROL_DST" || fail "Failed to set permissions on ${CONTROL_DST}."
cp "$TMP_INIT" "$INIT_DST" || fail "Failed to copy ${INIT_DST}."
chmod 0755 "$INIT_DST" || fail "Failed to set permissions on ${INIT_DST}."

if [ "$INSTALL_LUCI_COMMANDS" = "1" ] && ! pkg_installed luci-app-commands; then
    info "Installing luci-app-commands..."
    if ! pkg_install luci-app-commands; then
        warn "luci-app-commands installation failed. Core failover files are installed; LuCI buttons were skipped."
        INSTALL_LUCI_COMMANDS=0
    fi
fi

configure_luci_command() {
    section="$1"; name="$2"; command="$3"
    uci -q delete "luci.$section" >/dev/null 2>&1 || true
    uci set "luci.$section=command" || return 1
    uci set "luci.$section.name=$name" || return 1
    uci set "luci.$section.command=$command" || return 1
}
if [ "$INSTALL_LUCI_COMMANDS" = "1" ]; then
    info "Adding LuCI Custom Commands entries..."
    configure_luci_command pvf_status  'VPN Failover: Status'         '/usr/bin/podkop-vpn-failover status' || warn "Could not configure status command."
    configure_luci_command pvf_test    'VPN Failover: Test all VPNs'  '/usr/bin/podkop-vpn-failover test' || warn "Could not configure test command."
    configure_luci_command pvf_logs    'VPN Failover: Logs'            '/usr/bin/podkop-vpn-failover logs' || warn "Could not configure logs command."
    configure_luci_command pvf_config  'VPN Failover: Show settings'  '/usr/bin/podkop-vpn-failover config' || warn "Could not configure config command."
    configure_luci_command pvf_start   'VPN Failover: Enable + Start' '/usr/bin/podkop-vpn-failover-control start' || warn "Could not configure start command."
    configure_luci_command pvf_restart 'VPN Failover: Restart'        '/usr/bin/podkop-vpn-failover-control restart' || warn "Could not configure restart command."
    configure_luci_command pvf_stop    'VPN Failover: Stop + Disable' '/usr/bin/podkop-vpn-failover-control stop' || warn "Could not configure stop command."
    uci commit luci || warn "Could not commit LuCI commands."
fi

if [ "$existing_install" -eq 1 ]; then
    if [ "$was_enabled" -eq 1 ]; then "$INIT_DST" enable >/dev/null 2>&1 || fail "Failed to restore failover autostart state."
    else "$INIT_DST" disable >/dev/null 2>&1 || true; fi
    if [ "$was_running" -eq 1 ]; then
        info "Restoring running failover service..."
        "$CONTROL_DST" restart || fail "Updated files were installed, but the failover service could not be restarted."
    else "$INIT_DST" stop >/dev/null 2>&1 || true; fi
else
    "$INIT_DST" disable >/dev/null 2>&1 || true
    "$INIT_DST" stop >/dev/null 2>&1 || true
fi

rm -f "$TMP_WORKER" "$TMP_CONTROL" "$TMP_INIT"
trap - EXIT INT TERM
info "Installed ${TAG}."
if [ "$existing_install" -eq 1 ]; then
    printf 'Update complete. Previous service and autostart state preserved.\n'
else
    printf 'Safety state after first installation: service STOPPED, autostart DISABLED.\n'
    printf 'Verify before enabling: /usr/bin/podkop-vpn-failover test\n'
    printf 'Then enable with: /usr/bin/podkop-vpn-failover-control start\n'
fi
[ "$INSTALL_LUCI_COMMANDS" = "1" ] && printf 'LuCI actions: System -> Custom Commands.\n'
