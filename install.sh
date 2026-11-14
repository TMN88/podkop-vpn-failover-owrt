#!/bin/sh

set -u

TAG="podkop-vpn-failover"
BASE_URL="${PVF_BASE_URL:-https://raw.githubusercontent.com/TMN88/podkop-vpn-failover-owrt/main}"
WORKER_DST="/usr/bin/podkop-vpn-failover"
CONTROL_DST="/usr/bin/podkop-vpn-failover-control"
INIT_DST="/etc/init.d/podkop-vpn-failover"
LIB_DST="/usr/lib/podkop-vpn-failover/recovery.sh"
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
pkg_installed jq || need_update=1
if [ "$INSTALL_LUCI_COMMANDS" = "1" ] && ! pkg_installed luci-app-commands; then need_update=1; fi
if [ "$need_update" -eq 1 ]; then
    info "Updating package indexes (${PKG_MANAGER})..."
    if ! pkg_update; then warn "Package index update reported errors; continuing with available indexes."; fi
fi

if ! pkg_installed curl; then
    info "Installing curl..."
    pkg_install curl || fail "curl installation failed."
fi

if ! pkg_installed jq; then
    pkg_install jq || fail "jq installation failed."
fi

for cmd in logger awk sort cut sed grep sha256sum setsid ip nft awg ubus; do
    command -v "$cmd" >/dev/null 2>&1 || fail "$cmd is required."
done

# Reject ambiguous auto-detection before changing the installation.
backend="$(uci -q get vpn_failover.main.backend 2>/dev/null)"
[ -z "$(uci -q changes vpn_failover)" ] || fail "Save or revert pending VPN Failover settings before updating."
section="$(uci -q get vpn_failover.main.section 2>/dev/null)"
section="${section:-main}"
case "$section" in *[!a-zA-Z0-9_]*) fail "Invalid section name." ;; esac
if [ "${backend:-auto}" = auto ]; then
    candidates=""
    for pair in podkop:PodkopTable forkop:ForkopTable netshift:NetShiftTable; do
        candidate="${pair%:*}"; table="${pair#*:}"
        if nft list table inet "$table" >/dev/null 2>&1 || ubus call service list "{\"name\":\"$candidate\"}" | jq -e --arg p "$candidate" '.[$p].instances // {} | any(.[]; .running == true)' >/dev/null 2>&1; then
            candidates="$candidates $candidate"
        fi
    done
    set -- $candidates
    if [ "$#" = 1 ]; then backend="$1"; [ "$backend" != netshift ] || backend=forkozz
    else backend=auto; warn "Backend activity is ambiguous. Recovery will stay blocked until backend is selected explicitly."; fi
fi
case "$backend" in
    podkop) package=podkop ;;
    forkop) package=forkop ;;
    forkozz) package=netshift ;;
    auto) package="" ;;
    *) fail "Unknown backend." ;;
esac
if [ -n "$package" ]; then
    [ -x "/etc/init.d/$package" ] || fail "Backend init service is missing."
    [ "$backend" != forkozz ] || [ -x /usr/bin/netshift ] || fail "NetShift executable is missing."
    [ "$(uci -q get "$package.$section" 2>/dev/null)" = section ] || fail "Routing section does not exist."
fi

TMP_WORKER="/tmp/${TAG}.worker.$$"
TMP_CONTROL="/tmp/${TAG}.control.$$"
TMP_INIT="/tmp/${TAG}.init.$$"
TMP_UI="/tmp/${TAG}.ui.$$"
TMP_RPC="/tmp/${TAG}.rpc.$$"
TMP_MENU="/tmp/${TAG}.menu.$$"
TMP_ACL="/tmp/${TAG}.acl.$$"
TMP_LIB="/tmp/${TAG}.lib.$$"
trap 'rm -f "$TMP_WORKER" "$TMP_CONTROL" "$TMP_INIT" "$TMP_UI" "$TMP_RPC" "$TMP_MENU" "$TMP_ACL" "$TMP_LIB"' EXIT INT TERM

info "Downloading worker..."
fetch "${BASE_URL}/podkop-vpn-failover" "$TMP_WORKER" || fail "Failed to download worker from ${BASE_URL}."
fetch "${BASE_URL}/recovery.sh" "$TMP_LIB" || fail "Failed to download recovery library."
/bin/sh -n "$TMP_LIB" || fail "Invalid recovery library syntax."
[ -s "$TMP_LIB" ] || fail "Empty recovery library."
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

fetch "${BASE_URL}/vpn-failover.js" "$TMP_UI" || fail "Failed to download LuCI view."
fetch "${BASE_URL}/vpn-failover.rpc" "$TMP_RPC" || fail "Failed to download RPC."
fetch "${BASE_URL}/luci-menu.json" "$TMP_MENU" || fail "Failed to download menu."
fetch "${BASE_URL}/luci-acl.json" "$TMP_ACL" || fail "Failed to download ACL."
[ -s "$TMP_UI" ] || fail "Empty LuCI view."
/bin/sh -n "$TMP_RPC" || fail "Invalid RPC shell syntax."
jq -e 'type == "object"' "$TMP_MENU" >/dev/null || fail "Invalid menu JSON."
jq -e 'type == "object"' "$TMP_ACL" >/dev/null || fail "Invalid ACL JSON."

existing_install=0
was_running=0
was_enabled=0
if [ -x "$INIT_DST" ]; then
    existing_install=1
    "$INIT_DST" running >/dev/null 2>&1 && was_running=1
    "$INIT_DST" enabled >/dev/null 2>&1 && was_enabled=1
    BACKUP_DIR="/etc/podkop-vpn-failover-backups/$(date +%Y%m%dT%H%M%S)-$$"
    mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR" || fail "Cannot create backup."
    for source in "$WORKER_DST" "$CONTROL_DST" "$INIT_DST" "$LIB_DST" /etc/config/vpn_failover; do
        [ ! -f "$source" ] || cp -p "$source" "$BACKUP_DIR/$(echo "$source" | tr / _)" || fail "Backup failed."
    done
    # Migrate numeric settings from older customised workers without executing
    # the worker or evaluating shell text. Existing UCI values always win.
    for mapping in CHECK_INTERVAL:check_interval FAIL_THRESHOLD:fail_threshold CANDIDATE_SUCCESS_THRESHOLD:candidate_success_threshold CONNECT_TIMEOUT:connect_timeout MAX_TIME:max_time STARTUP_GRACE_PERIOD:startup_grace_period NO_RESERVE_RETRY_INTERVAL:no_reserve_retry_interval QUARANTINE_SECONDS:quarantine_seconds; do
        old="${mapping%:*}"; option="${mapping#*:}"
        uci -q get "vpn_failover.main.$option" >/dev/null 2>&1 && continue
        value="$(tr -d '\r' < "$WORKER_DST" | sed -n "s/^$old=\([0-9][0-9]*\)$/\1/p" | head -n1)"
        case "$value" in ''|*[!0-9]*) continue;; esac
        uci -q get vpn_failover.main >/dev/null || uci set vpn_failover.main=settings || fail "Cannot migrate settings."
        uci set "vpn_failover.main.$option=$value" || fail "Cannot migrate $option."
    done
    uci commit vpn_failover || fail "Cannot save migrated settings."
    info "Stopping existing failover service before update..."
    "$INIT_DST" stop >/dev/null 2>&1 || true
fi

mkdir -p /usr/lib/podkop-vpn-failover || fail "Cannot create library directory."
cp "$TMP_LIB" "$LIB_DST" && chmod 0644 "$LIB_DST" || fail "Cannot install recovery library."
cp "$TMP_WORKER" "$WORKER_DST" || fail "Failed to copy ${WORKER_DST}."
chmod 0755 "$WORKER_DST" || fail "Failed to set permissions on ${WORKER_DST}."
cp "$TMP_CONTROL" "$CONTROL_DST" || fail "Failed to copy ${CONTROL_DST}."
chmod 0755 "$CONTROL_DST" || fail "Failed to set permissions on ${CONTROL_DST}."
cp "$TMP_INIT" "$INIT_DST" || fail "Failed to copy ${INIT_DST}."
chmod 0755 "$INIT_DST" || fail "Failed to set permissions on ${INIT_DST}."

mkdir -p /www/luci-static/resources/view /usr/libexec/rpcd /usr/share/luci/menu.d /usr/share/rpcd/acl.d || fail "Cannot create UI directories."
cp "$TMP_UI" /www/luci-static/resources/view/vpn-failover.js || fail "Cannot install view."
cp "$TMP_RPC" /usr/libexec/rpcd/vpn-failover || fail "Cannot install RPC."
cp "$TMP_MENU" /usr/share/luci/menu.d/vpn-failover.json || fail "Cannot install menu."
cp "$TMP_ACL" /usr/share/rpcd/acl.d/vpn-failover.json || fail "Cannot install ACL."
chmod 0755 /usr/libexec/rpcd/vpn-failover || fail "Cannot set RPC permissions."
chmod 0644 /www/luci-static/resources/view/vpn-failover.js /usr/share/luci/menu.d/vpn-failover.json /usr/share/rpcd/acl.d/vpn-failover.json || fail "Cannot set UI permissions."
if ! uci -q get vpn_failover.main >/dev/null 2>&1; then
    [ -e /etc/config/vpn_failover ] || touch /etc/config/vpn_failover || fail "Cannot create UCI config file."
    uci set vpn_failover.main=settings && uci set "vpn_failover.main.backend=$backend" && uci set "vpn_failover.main.section=$section" && uci commit vpn_failover || fail "Cannot create settings."
fi
# An explicit per-section pool must be reviewed by its owner. Never silently
# borrow every awg* interface (possibly XBOX/CRYPTO) from another section.
if ! uci -q get vpn_failover.main.recovery_enabled >/dev/null; then
    uci set vpn_failover.main.recovery_enabled=1 && uci commit vpn_failover || fail "Cannot store recovery permission."
fi
warn "Recovery now starts stopped backend/sing-box while Failover is active. Pause Failover before maintenance."
uci -q get vpn_failover.main.interfaces >/dev/null || warn "No reserve allowlist configured; only same-tunnel runtime recovery is available."
/etc/init.d/rpcd restart || fail "Cannot refresh rpcd."
rpc_ready=0
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if ubus list vpn-failover 2>/dev/null | grep -qx vpn-failover; then rpc_ready=1; break; fi
    sleep 1
done
[ "$rpc_ready" = 1 ] || fail "VPN Failover RPC did not register after rpcd restart."

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
    configure_luci_command pvf_history 'VPN Failover: Operations' '/usr/bin/podkop-vpn-failover history' || warn "Could not configure history command."
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

rm -f "$TMP_WORKER" "$TMP_CONTROL" "$TMP_INIT" "$TMP_UI" "$TMP_RPC" "$TMP_MENU" "$TMP_ACL" "$TMP_LIB"
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

printf 'Operations journal: LuCI -> Services -> VPN Failover (sign in again if needed).\n'
