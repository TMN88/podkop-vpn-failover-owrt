#!/bin/sh
# Sourced by the worker. Runtime dependencies: ash, jq, curl, ip-full, awg,
# ubus, nft, setsid. No configuration is evaluated as shell code.
OP_LIMIT=180
RUNTIME_WAIT=60
HOLD_SECONDS=120
STABLE_SECONDS=10
OP_LOCK="${STATE_DIR}.operation"
PROBE_CODE=TEST_UNAVAILABLE
RECOVERY_STATE=OBSERVING
OP_ID=""
DEADLINE=0
EXPECTED_CONFIG=""
OWNED_KEY=""
OWNED_FROM=""
OWNED_TO=""
CHILD=""
ROUTE_TABLE=""
ROUTE_PREF=""
ROUTE_DEV=""

monotonic() { cut -d. -f1 /proc/uptime; }
boot_id() { cat /proc/sys/kernel/random/boot_id; }
identity() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }
valid_name() { case "$1" in ''|*[!a-zA-Z0-9_]*) return 1;; esac; }
valid_device() { case "$1" in ''|*[!a-zA-Z0-9_.-]*) return 1;; esac; [ "${#1}" -le 15 ]; }
trusted_directory() {
    [ ! -L "$1" ] && [ -d "$1" ] || return 1
    if command -v stat >/dev/null 2>&1; then
        [ "$(stat -c '%u:%a' "$1" 2>/dev/null)" = 0:700 ]
    else
        # Stock OpenWrt BusyBox may omit stat. Numeric ls is sufficient for
        # this exact root-owned 0700 directory contract; never accept a link.
        ls -nd "$1" 2>/dev/null | awk '$1=="drwx------" && $3==0 {ok=1} END {exit !ok}'
    fi
}
number() { case "$1" in ''|*[!0-9]*) return 1;; esac; }
setting() { uci -q get "vpn_failover.main.$1" 2>/dev/null; }
backend_label() {
    case "${1:-$BACKEND}" in
        podkop) printf 'Podkop';;
        forkop) printf 'Forkop';;
        forkozz) printf 'Forkozz (NetShift)';;
        *) printf 'Обход не определён';;
    esac
}
backend_line() { printf '[%s] %s\n' "$(backend_label)" "$*"; }
numeric_setting() {
    local value
    value="$(setting "$1")"
    if number "$value" && [ "$value" -ge "$3" ] && [ "$value" -le "$4" ]; then
        printf '%s' "$value"
    else printf '%s' "$2"; fi
}
load_settings() {
    CHECK_INTERVAL="$(numeric_setting check_interval "$CHECK_INTERVAL" 1 3600)"
    FAIL_THRESHOLD="$(numeric_setting fail_threshold "$FAIL_THRESHOLD" 1 100)"
    CANDIDATE_SUCCESS_THRESHOLD="$(numeric_setting candidate_success_threshold "$CANDIDATE_SUCCESS_THRESHOLD" 1 10)"
    CONNECT_TIMEOUT="$(numeric_setting connect_timeout "$CONNECT_TIMEOUT" 1 10)"
    MAX_TIME="$(numeric_setting max_time "$MAX_TIME" 1 15)"
    STARTUP_GRACE_PERIOD="$(numeric_setting startup_grace_period "$STARTUP_GRACE_PERIOD" 0 3600)"
    NO_RESERVE_RETRY_INTERVAL="$(numeric_setting no_reserve_retry_interval "$NO_RESERVE_RETRY_INTERVAL" 1 86400)"
    QUARANTINE_SECONDS="$(numeric_setting quarantine_seconds "$QUARANTINE_SECONDS" 0 86400)"
}
paused() { [ "$(setting paused)" = 1 ]; }
recovery_allowed() { ! paused && [ "$(setting recovery_enabled)" != 0 ]; }

# Auto detection uses live evidence, never the mere existence of a UCI file.
adapter_active() {
    local package="$1" table="$2"
    nft list table inet "$table" >/dev/null 2>&1 && return 0
    ubus call service list "{\"name\":\"$package\"}" 2>/dev/null |
        jq -e --arg p "$package" '.[$p].instances // {} | any(.[]; .running == true)' >/dev/null 2>&1
}
adapter() {
    local method="$1"
    shift
    case "$method" in detect|read_section|get_current_interface|set_interface|apply|runtime_state|ensure_started|verify_binding|verify_path|rollback) ;; *) return 2;; esac
    case "$BACKEND" in podkop|forkop|forkozz) "${BACKEND}_${method}" "$@";; *) return 2;; esac
}
# Explicit adapters share guarded field writes and the runtime verifier, but
# keep backend schema, identity and native lifecycle separate.
podkop_detect() { adapter_active podkop PodkopTable; }
forkop_detect() { adapter_active forkop ForkopTable; }
forkozz_detect() { adapter_active netshift NetShiftTable; }
podkop_read_section() { INTERFACE_KEY="podkop.$SECTION.interface"; }
forkozz_read_section() { INTERFACE_KEY="netshift.$SECTION.interface"; }
podkop_get_current_interface() { uci -q get "$INTERFACE_KEY" 2>/dev/null; }
forkop_get_current_interface() { uci -q get "$INTERFACE_KEY" 2>/dev/null; }
forkozz_get_current_interface() { uci -q get "$INTERFACE_KEY" 2>/dev/null; }
podkop_set_interface() { guarded_set_interface "$@"; }
forkop_set_interface() { guarded_set_interface "$@"; }
forkozz_set_interface() { guarded_set_interface "$@"; }
podkop_apply() { if podkop_runtime_ready; then bounded 60 /etc/init.d/podkop reload; else bounded 60 /etc/init.d/podkop start; fi; }
forkop_apply() { if podkop_runtime_ready; then bounded 60 /etc/init.d/forkop reload; else bounded 60 /etc/init.d/forkop start; fi; }
forkozz_apply() { if podkop_runtime_ready; then bounded 60 /usr/bin/netshift reload; else bounded 60 /etc/init.d/netshift start; fi; }
podkop_runtime_state() { runtime_pid; }
forkop_runtime_state() { runtime_pid; }
forkozz_runtime_state() { runtime_pid; }
podkop_ensure_started() { ensure_started; }
forkop_ensure_started() { ensure_started; }
forkozz_ensure_started() { ensure_started; }
podkop_verify_binding() { verify_podkop_binding "$@"; }
forkop_verify_binding() { verify_podkop_binding "$@"; }
forkozz_verify_binding() { verify_podkop_binding "$@"; }
podkop_verify_path() { verify_path "$@"; }
forkop_verify_path() { verify_path "$@"; }
forkozz_verify_path() { verify_path "$@"; }
podkop_rollback() { rollback_operation; }
forkop_rollback() { rollback_operation; }
forkozz_rollback() { rollback_operation; }
select_backend() {
    local requested candidates="" package
    BACKEND_ERROR=""; BACKEND=""; CONFIG_PACKAGE=""; INTERFACE_KEY=""
    SECTION="$(setting section)"; SECTION="${SECTION:-main}"
    valid_name "$SECTION" || { SECTION=""; BACKEND_ERROR=INVALID_SECTION; return 1; }
    requested="$(setting backend)"
    case "${requested:-auto}" in
        auto)
            adapter_active podkop PodkopTable && candidates="$candidates podkop"
            adapter_active forkop ForkopTable && candidates="$candidates forkop"
            adapter_active netshift NetShiftTable && candidates="$candidates forkozz"
            set -- $candidates
            [ "$#" = 1 ] || { BACKEND_ERROR=BACKEND_AMBIGUOUS; return 1; }
            BACKEND="$1" ;;
        podkop|forkop|forkozz) BACKEND="$requested" ;;
        *) BACKEND_ERROR=UNKNOWN_BACKEND; return 1 ;;
    esac
    case "$BACKEND" in
        podkop) CONFIG_PACKAGE=podkop; NFT_TABLE=PodkopTable ;;
        forkop) CONFIG_PACKAGE=forkop; NFT_TABLE=ForkopTable ;;
        forkozz) CONFIG_PACKAGE=netshift; NFT_TABLE=NetShiftTable ;;
    esac
    PODKOP_INIT="/etc/init.d/$CONFIG_PACKAGE"
    [ "$(uci -q get "$CONFIG_PACKAGE.$SECTION" 2>/dev/null)" = section ] || {
        BACKEND_ERROR=SECTION_MISSING; return 1;
    }
    SING_BOX_CONFIG="$(uci -q get "$CONFIG_PACKAGE.settings.config_path" 2>/dev/null)"
    SING_BOX_CONFIG="${SING_BOX_CONFIG:-/etc/sing-box/config.json}"
    case "$SING_BOX_CONFIG" in /*) ;; *) BACKEND_ERROR=INVALID_CONFIG_PATH; return 1;; esac
    adapter read_section || { BACKEND_ERROR=UNSUPPORTED_SECTION_SCHEMA; return 1; }
}

forkop_read_section() {
    local child owner count=0 found="" value
    # Forkop 2: owned section_interface children, not .section_interface on parent.
    # Never modify selector/proxy/subscription groups or a multi-interface section.
    for child in $(uci -q show forkop 2>/dev/null | sed -n 's/^forkop\.\([a-zA-Z0-9_]*\)=section_interface$/\1/p'); do
        owner="$(uci -q get "forkop.$child.section" 2>/dev/null)"
        [ "$owner" = "$SECTION" ] || continue
        count=$((count + 1)); found="forkop.$child.name"
    done
    [ "$count" -le 1 ] || return 1
    if [ "$count" = 1 ]; then INTERFACE_KEY="$found"; return 0; fi
    for child in section_interface interfaces interface; do
        value="$(uci -q get "forkop.$SECTION.$child" 2>/dev/null)"
        [ -n "$value" ] || continue
        valid_name "$value" || return 1
        [ "$child" != section_interface ] || [ "$(uci -q get "network.$value.proto")" = amneziawg ] || return 1
        INTERFACE_KEY="forkop.$SECTION.$child"
        return 0
    done
    return 1
}
get_current_interface() {
    [ -z "$BACKEND_ERROR" ] && [ -n "$INTERFACE_KEY" ] || return 1
    adapter get_current_interface
}
get_connection_type() {
    local mode
    [ -z "$BACKEND_ERROR" ] || return 1
    [ "$(uci -q get "$CONFIG_PACKAGE.$SECTION.enabled" 2>/dev/null)" != 0 ] || return 1
    case "$(uci -q get "$CONFIG_PACKAGE.$SECTION.disabled" 2>/dev/null)" in 1|true|on|yes) return 1;; esac
    if [ "$BACKEND" = forkop ]; then
        mode="$(uci -q get "$CONFIG_PACKAGE.$SECTION.action" 2>/dev/null)"
        case "$mode" in
            vpn|connection)
                # A connection containing anything but one interface is not a VPN leaf.
                [ "$(uci -q get "$CONFIG_PACKAGE.$SECTION.urltest_enabled" 2>/dev/null)" != 1 ] || return 1
                for mode in selector_proxy_links selector_subscription_urls selector_outbound_jsons outbound_json proxy_string; do
                    [ -z "$(uci -q get "$CONFIG_PACKAGE.$SECTION.$mode" 2>/dev/null)" ] || return 1
                done
                {
                    # Forkop 2 ITEM_TYPES plus legacy proxy/group types.
                    for mode in $(uci -q show forkop | sed -n 's/^forkop\.\([a-zA-Z0-9_]*\)=\(subscription_url\|connection_link\|proxy_link\|outbound_json\|urltest\|priority_group\|fallback_group\|fallback_level\|tunnel\|tunnel_peer\)$/\1/p'); do
                        [ "$(uci -q get "forkop.$mode.section")" != "$SECTION" ] || return 1
                    done
                }
                echo vpn;;
            *) printf '%s\n' "$mode";;
        esac
    else uci -q get "$CONFIG_PACKAGE.$SECTION.connection_type" 2>/dev/null; fi
}

discover_interfaces() {
    local pool iface current
    pool="$(setting interfaces)"; current="$(get_current_interface)"
    # Explicit per-selected-section allowlist. Absence is fail-closed; do not
    # appropriate XBOX/CRYPTO or another section's tunnels by scanning awg*.
    for iface in $pool; do
        valid_name "$iface" || continue
        [ "$(uci -q get "network.$iface.proto" 2>/dev/null)" = amneziawg ] || continue
        printf '%s\n' "$iface"
    done | sort -u
}
allowed_interface() { discover_interfaces | grep -Fxq "$1"; }
tunnel_inventory() {
    { if valid_name "$1" && [ "$(uci -q get "network.$1.proto")" = amneziawg ]; then
        printf '%s\n' "$1"
      fi
      discover_interfaces
    } | sort -u
}

# Fingerprint both packages including outstanding UCI deltas. Only the hash,
# never config values/keys/subscriptions, may leave the private operation.
config_fingerprint() {
    { backend_config_fingerprint_data
      uci -q export vpn_failover; uci -q changes vpn_failover;
      uci -q export network; uci -q changes network; } 2>/dev/null | sha256sum | cut -d' ' -f1
}
backend_config_fingerprint_data() {
    if [ "$BACKEND" = forkozz ]; then
        # NetShift start/stop owns this crash-recovery flag (1 -> 0 on start).
        # It is lifecycle state, not a user routing/DNS/subscription change.
        # Keep EVERY other field and pending delta in the concurrency guard.
        uci -q export netshift | awk '$1=="config" {s=($3=="\047settings\047")} !(s && $1=="option" && $2=="shutdown_correctly")'
        uci -q changes netshift | sed '/^netshift\.settings\.shutdown_correctly=/d'
    else
        uci -q export "$CONFIG_PACKAGE"; uci -q changes "$CONFIG_PACKAGE"
    fi
}
config_unchanged() {
    [ "$(cat "$STATE_DIR/cancel-generation" 2>/dev/null)" = "${CANCEL_TOKEN:-}" ] || { REASON=OPERATION_CANCELLED; return 1; }
    [ -z "$EXPECTED_CONFIG" ] || [ "$(config_fingerprint)" = "$EXPECTED_CONFIG" ] || {
        REASON=CONFIG_CHANGED_EXTERNALLY; return 1;
    }
    recovery_allowed || { REASON=PAUSED; return 1; }
}
remaining() {
    local left=$((DEADLINE - $(monotonic)))
    [ "$left" -gt 0 ] || return 1
    printf '%s\n' "$left"
}
kill_child() {
    [ -n "$CHILD" ] || return 0
    if [ -n "$CHILD_ID" ] && [ "$(identity "$CHILD")" = "$CHILD_ID" ]; then
        kill -TERM -- "-$CHILD" 2>/dev/null || kill -TERM "$CHILD" 2>/dev/null || :
        sleep 1
        [ "$(identity "$CHILD")" != "$CHILD_ID" ] || kill -KILL -- "-$CHILD" 2>/dev/null || :
    fi
    wait "$CHILD" 2>/dev/null || :
    CHILD=""
    rm -f "$OP_LOCK/child"
}
reap_child() {
    local dir="$1" pid stamp group
    [ -r "$dir/child" ] || return 0
    read -r pid stamp < "$dir/child"
    number "$pid" && [ -n "$stamp" ] || return 1
    if [ "$(identity "$pid")" = "$stamp" ]; then
        group="$(awk '{print $5}' "/proc/$pid/stat" 2>/dev/null)"
        [ "$group" = "$pid" ] || return 1
        kill -KILL -- "-$pid" 2>/dev/null || return 1
    fi
    rm -f "$dir/child"
}
bounded() {
    local limit="$1" until rc
    shift
    until=$(( $(monotonic) + limit ))
    [ "$until" -le "$DEADLINE" ] || until="$DEADLINE"
    [ "$(monotonic)" -lt "$until" ] || { REASON=DEADLINE; return 124; }
    command -v setsid >/dev/null 2>&1 || { REASON=SETSID_REQUIRED; return 2; }
    setsid "$@" > "$OP_LOCK/command-output" 2>&1 &
    CHILD=$!; CHILD_ID="$(identity "$CHILD")"
    [ -z "$CHILD_ID" ] || printf '%s %s\n' "$CHILD" "$CHILD_ID" > "$OP_LOCK/child"
    while kill -0 "$CHILD" 2>/dev/null; do
        if [ "$(monotonic)" -ge "$until" ]; then REASON=DEADLINE; kill_child; return 124; fi
        if ! config_unchanged; then kill_child; return 3; fi
        sleep 1
    done
    wait "$CHILD"; rc=$?; CHILD=""; rm -f "$OP_LOCK/child"
    return "$rc"
}

operation() {
    local event="$1" from="$2" to="$3" detail="$4" tmp
    ensure_state_dir || return 1
    valid_name "$from" || from=""
    valid_name "$to" || to=""
    # Details are internal codes only. Never retain command output or URLs.
    detail="$(printf '%s' "$detail" | tr '\t\r\n' '   ' | sed 's#https\?://[^ ]*#[URL REDACTED]#g' | cut -c1-700)"
    tmp="$HISTORY_FILE.$$"
    { [ ! -r "$HISTORY_FILE" ] || tail -n "$((HISTORY_LIMIT - 1))" "$HISTORY_FILE"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
        "$BACKEND" "$SECTION" "$event" "$from" "$to" "op=$OP_ID state=$RECOVERY_STATE $detail" "$(date +%s)"
    } > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$HISTORY_FILE"
}
state() {
    RECOVERY_STATE="$1"; REASON="${2:-}"
    printf '%s\n' "$RECOVERY_STATE" > "$STATE_DIR/state"
    printf '%s\n' "$REASON" > "$STATE_DIR/reason"
    printf '%s\n' "$DEADLINE" > "$STATE_DIR/deadline"
    printf '%s\n' "${START_ATTEMPTS:-0}" > "$STATE_DIR/attempts"
}
event() { operation "$1" "${OWNED_FROM:-$CURRENT}" "${OWNED_TO:-$CURRENT}" "reason=${2:-$REASON} result=$1 probe=$PROBE_CODE attempt=${START_ATTEMPTS:-0} deadline=$DEADLINE"; }

acquire_operation() {
    local owner stamp owner_boot
    ensure_state_dir || return 1
    if ! mkdir "$OP_LOCK" 2>/dev/null; then
        trusted_directory "$OP_LOCK" || return 1
        owner="$(cat "$OP_LOCK/pid" 2>/dev/null)"
        stamp="$(cat "$OP_LOCK/identity" 2>/dev/null)"
        owner_boot="$(cat "$OP_LOCK/boot" 2>/dev/null)"
        # A creator without its metadata is never reaped by a contender.
        number "$owner" && [ -n "$stamp" ] || return 1
        if [ "$owner_boot" = "$(boot_id)" ] && [ "$(identity "$owner")" = "$stamp" ]; then return 1; fi
        mkdir "$OP_LOCK/reap" 2>/dev/null || return 1
        reap_child "$OP_LOCK" || { rmdir "$OP_LOCK/reap"; return 1; }
        cleanup_routes "$OP_LOCK" || { rmdir "$OP_LOCK/reap"; return 1; }
        # Known private files only. Never recursively remove an arbitrary path.
        cleanup_operation_files
        rmdir "$OP_LOCK/reap" && rmdir "$OP_LOCK" && mkdir "$OP_LOCK" || return 1
    fi
    trusted_directory "$OP_LOCK" || return 1
    chmod 700 "$OP_LOCK"
    printf '%s\n' "$$" > "$OP_LOCK/pid"
    identity "$$" > "$OP_LOCK/identity"
    boot_id > "$OP_LOCK/boot"
    OP_ID="$(boot_id | cut -c1-8)-$(monotonic)-$$"
    printf '%s\n' "$OP_ID" > "$OP_LOCK/id"
    # Two seconds are reserved for terminating the owned process group and
    # removing exact routing resources within the 180-second operation budget.
    DEADLINE=$(( $(monotonic) + OP_LIMIT - 2 ))
    EXPECTED_CONFIG=""; OWNED_KEY=""; OWNED_FROM=""; OWNED_TO=""; START_ATTEMPTS=0
    CANCEL_TOKEN="$(cat "$STATE_DIR/cancel-generation" 2>/dev/null)"
    trap 'release_operation' EXIT
    trap 'kill_child; interrupted_recovery; release_operation; exit 143' TERM INT HUP
    return 0
}
release_operation() {
    kill_child
    cleanup_routes "$OP_LOCK" || return 1
    [ "$(cat "$OP_LOCK/pid" 2>/dev/null)" = "$$" ] || return 0
    cleanup_operation_files
    rmdir "$OP_LOCK" 2>/dev/null || :
    EXPECTED_CONFIG=""; OWNED_KEY=""; DEADLINE=0
    trap - EXIT TERM INT HUP
    [ "${DAEMON_MODE:-0}" != 1 ] || trap 'cleanup_daemon_local; exit 0' TERM INT HUP
}
cleanup_operation_files() {
    rm -f "$OP_LOCK/pid" "$OP_LOCK/identity" "$OP_LOCK/boot" "$OP_LOCK/command-output" "$OP_LOCK/probe-body" \
      "$OP_LOCK/config.before" "$OP_LOCK/runtime.before" "$OP_LOCK/services.before" "$OP_LOCK/route" "$OP_LOCK/child" \
      "$OP_LOCK/logs.before" "$OP_LOCK/log.cursor" "$OP_LOCK/logs.after" "$OP_LOCK/logs.new" "$OP_LOCK/id"
}
cleanup_daemon_local() {
    [ "$(cat "$PID_FILE" 2>/dev/null)" != "$$" ] || { rm -f "$PID_FILE"; rmdir "$LOCK_DIR" 2>/dev/null || :; }
}
interrupted_recovery() {
    # Never silently declare rollback healthy after termination or a crash.
    state RECOVERY_FAILED INTERRUPTED
    event RECOVERY_FAILED
}

# Each probe owns a previously empty table and a previously unused priority.
# The oif rule affects only sockets explicitly bound to this AWG device.
# Manifest precedes mutations, so the next lock owner can reap a crash.
prepare_routes() {
    local dev="$1" n table pref
    cleanup_routes "$OP_LOCK" || return 2
    for n in 0 1 2 3 4 5 6 7; do
        table=$((42800 + n)); pref=$((1 + n))
        [ -z "$(ip -4 route show table "$table" 2>/dev/null)" ] || continue
        ip -4 rule show | grep -Eq "(^|[[:space:]])(lookup|table) $table([[:space:]]|$)|^$pref:" && continue
        # A preceding non-local policy could steal the probe; fail closed.
        ip -4 rule show | awk -F: -v p="$pref" '$1+0 > 0 && $1+0 < p {found=1} END {exit !found}' && continue
        printf '%s %s %s\n' "$table" "$pref" "$dev" > "$OP_LOCK/route"
        ip -4 route add table "$table" default dev "$dev" proto 186 || return 2
        ip -4 rule add pref "$pref" oif "$dev" lookup "$table" protocol 186 || return 2
        ROUTE_TABLE="$table"; ROUTE_PREF="$pref"; ROUTE_DEV="$dev"
        return 0
    done
    return 2
}
cleanup_routes() {
    local dir="$1" table pref dev rules routes
    [ -r "$dir/route" ] || return 0
    read -r table pref dev < "$dir/route"
    case "$table:$pref" in 4280[0-7]:[1-8]) ;; *) return 1;; esac
    valid_device "$dev" || return 1
    # Delete exact owned selectors/routes, never flush a table. Protocol marks
    # distinguish our resources from a foreign replacement after a crash.
    rules="$(ip -N -4 rule show)" || return 1
    if printf '%s\n' "$rules" | grep -Eq "^$pref:.*oif $dev .*lookup $table .*proto(col)? (186|0xba)"; then
        ip -4 rule del pref "$pref" oif "$dev" lookup "$table" protocol 186 || return 1
    fi
    routes="$(ip -N -4 route show table "$table")" || return 1
    if printf '%s\n' "$routes" | grep -Eq "^default dev $dev .*proto (186|0xba)"; then
        ip -4 route del table "$table" default dev "$dev" proto 186 || return 1
    fi
    rm -f "$dir/route"
    ROUTE_TABLE=""; ROUTE_PREF=""; ROUTE_DEV=""
}

interface_state() {
    local iface="$1" info endpoint route
    valid_name "$iface" || { PROBE_CODE=TEST_UNAVAILABLE; return 2; }
    [ "$(uci -q get "network.$iface.proto" 2>/dev/null)" = amneziawg ] || { PROBE_CODE=INTERFACE_DOWN; return 1; }
    info="$(ubus call "network.interface.$iface" status 2>/dev/null)"
    if ! printf '%s' "$info" | jq -e '.up == true' >/dev/null 2>&1; then
        [ "$iface" != "$CURRENT" ] && allowed_interface "$iface" || { PROBE_CODE=INTERFACE_DOWN; return 1; }
        bounded 10 ifup "$iface" || { PROBE_CODE=INTERFACE_DOWN; return 1; }
        info="$(ubus call "network.interface.$iface" status 2>/dev/null)"
    fi
    DEVICE="$(printf '%s' "$info" | jq -er 'select(.up == true) | .l3_device // .device' 2>/dev/null)"
    valid_device "$DEVICE" || { PROBE_CODE=INTERFACE_DOWN; return 1; }
    # Endpoint output contains a public peer key; strip it immediately, never log.
    endpoint="$(awg show "$DEVICE" endpoints 2>/dev/null | awk 'NF == 2 {print $2}')"
    [ "$(printf '%s\n' "$endpoint" | wc -l)" = 1 ] && [ -n "$endpoint" ] || { PROBE_CODE=TEST_UNAVAILABLE; return 2; }
    ENDPOINT="$endpoint"
    case "$endpoint" in
        \[*\]:*) endpoint="${endpoint#\[}"; endpoint="${endpoint%\]:*}"; route="$(ip -6 route get "$endpoint" 2>/dev/null)" ;;
        *:*) endpoint="${endpoint%:*}"; route="$(ip -4 route get "$endpoint" 2>/dev/null)" ;;
        *) PROBE_CODE=TEST_UNAVAILABLE; return 2;;
    esac
    [ -n "$route" ] || { PROBE_CODE=WAITING_NETWORK; return 2; }
    printf '%s\n' "$route" | grep -Eq "dev $DEVICE([[:space:]]|$)" && { PROBE_CODE=ENDPOINT_ROUTE_LOOP; return 2; }
    return 0
}
awg_rx() { awg show "$DEVICE" transfer 2>/dev/null | awk '{s+=$2} END {printf "%.0f\n",s}'; }
awg_handshake() { awg show "$DEVICE" latest-handshakes 2>/dev/null | awk '$2 > 0 {ok=1} END {exit !ok}'; }
probe_curl() {
    local left
    left="$(remaining)" || return 124
    [ "$left" -le "$MAX_TIME" ] || left="$MAX_TIME"
    # Ignore proxy environment for tunnel checks; explicit local proxy options
    # below can deliberately override this default. Never disable TLS checks.
    command curl -q --proxy '' --noproxy '*' "$@" --max-time "$left" --max-filesize 65536
}

# Independent pinned DoH bootstrap, never a query to the local FakeIP resolver.
# Cache is limited to five monotonic minutes and invalidated on reboot (/tmp).
resolve_target() {
    local host="$1" dev="$2" proxy="$3" resolver pin path result ip cache stamp
    cache="$STATE_DIR/dns-$host"
    if [ -r "$cache" ]; then
        read -r stamp ip < "$cache"
        if number "$stamp" && [ "$(( $(monotonic) - stamp ))" -ge 0 ] && [ "$(( $(monotonic) - stamp ))" -le 300 ]; then
            printf '%s\n' "$ip"; return 0
        fi
    fi
    for resolver in cloudflare-dns.com dns.google; do
        case "$resolver" in
            cloudflare-dns.com) pin=1.1.1.1; path=dns-query;;
            dns.google) pin=8.8.8.8; path=resolve;;
        esac
        set -- --interface "$dev"
        [ -z "$proxy" ] || set -- --proxy "$proxy" --noproxy ''
        result="$(probe_curl -4 -fsS --connect-timeout "$CONNECT_TIMEOUT" \
            "$@" --resolve "$resolver:443:$pin" -H 'Accept: application/dns-json' \
            "https://$resolver/$path?name=$host&type=A" 2>/dev/null)" || continue
        ip="$(printf '%s' "$result" | jq -er 'select(.Status == 0) | .Answer[]? | select(.type == 1) | .data' 2>/dev/null | head -n1)"
        # Reject FakeIP/private/loopback/captive DNS answers.
        printf '%s\n' "$ip" | awk -F. 'NF==4 && $1>0 && $1<224 && $1!=10 && $1!=127 && !($1==169&&$2==254) && !($1==172&&$2>=16&&$2<=31) && !($1==192&&$2==168) && !($1==198&&($2==18||$2==19)) {for(i=1;i<=4;i++)if($i!~/^[0-9]+$/||$i>255)exit 1; exit 0} {exit 1}' || continue
        printf '%s %s\n' "$(monotonic)" "$ip" > "$cache"
        printf '%s\n' "$ip"; return 0
    done
    return 2
}

https_targets() {
    local dev="$1" proxy="${2:-}" host path ip result code good=0 resolved=0 rx_before rx_after
    PROBE_CODE=DNS_FAILURE; PROBE_HTTP=000; PROBE_RC=2; EGRESS=""
    rx_before="$(awg_rx)"
    for host in www.cloudflare.com www.msftconnecttest.com; do
        remaining >/dev/null && config_unchanged || { PROBE_CODE=TEST_UNAVAILABLE; return 2; }
        ip="$(resolve_target "$host" "$dev" "$proxy")" || continue
        resolved=$((resolved + 1))
        case "$host" in www.cloudflare.com) path=/cdn-cgi/trace;; *) path=/connecttest.txt;; esac
        set -- --interface "$dev"
        [ -z "$proxy" ] || set -- --proxy "$proxy" --noproxy ''
        code="$(probe_curl -4 -sS --connect-timeout "$CONNECT_TIMEOUT" \
            "$@" --resolve "$host:443:$ip" -o "$OP_LOCK/probe-body" -w '%{http_code}' "https://$host$path" 2>/dev/null)"
        PROBE_RC=$?; PROBE_HTTP="$code"
        [ "$PROBE_RC" = 0 ] && [ "$code" = 200 ] || continue
        case "$host" in
            www.cloudflare.com)
                grep -Eq '^ip=[0-9a-fA-F:.]+$' "$OP_LOCK/probe-body" && grep -q '^tls=TLS' "$OP_LOCK/probe-body" || continue
                EGRESS="$(sed -n 's/^ip=//p' "$OP_LOCK/probe-body" | tr -d '\r')"
                if [ -n "$(setting "expected_egress_$CURRENT_PROBE")" ] && [ "$EGRESS" != "$(setting "expected_egress_$CURRENT_PROBE")" ]; then
                    PROBE_CODE=UNEXPECTED_EGRESS; return 1
                fi;;
            *) [ "$(cat "$OP_LOCK/probe-body")" = 'Microsoft Connect Test' ] || continue;;
        esac
        good=$((good + 1))
    done
    if [ "$good" -gt 0 ]; then
        rx_after="$(awg_rx)"
        awg_handshake || { PROBE_CODE=NO_HANDSHAKE; return 1; }
        [ "$rx_after" -gt "$rx_before" ] || { PROBE_CODE=NO_DATA; return 1; }
        # Configured egress requires the trace result, not only Microsoft's body.
        [ -z "$(setting "expected_egress_$CURRENT_PROBE")" ] || [ -n "${EGRESS:-}" ] || { PROBE_CODE=TEST_UNAVAILABLE; return 2; }
        PROBE_CODE=HEALTHY; return 0
    fi
    [ "$resolved" -gt 0 ] || { PROBE_CODE=DNS_FAILURE; return 2; }
    awg_handshake || { PROBE_CODE=NO_HANDSHAKE; return 1; }
    PROBE_CODE=HTTPS_FAILURE; return 1
}
probe_interface_impl() {
    local iface="$1" rc
    CURRENT_PROBE="$iface"; EGRESS=""; PROBE_CODE=TEST_UNAVAILABLE
    printf '%s\n' "$iface" > "$STATE_DIR/probing"
    remaining >/dev/null || return 2
    interface_state "$iface" || return $?
    prepare_routes "$DEVICE" || { PROBE_CODE=TEST_UNAVAILABLE; cleanup_routes "$OP_LOCK"; return 2; }
    https_targets "$DEVICE"; rc=$?
    cleanup_routes "$OP_LOCK" || { PROBE_CODE=TEST_UNAVAILABLE; return 2; }
    return "$rc"
}
record_check() {
    local iface="$1" rc="$2" tmp="$STATE_DIR/last-check.json.$$"
    # Only a completed real probe writes this record. Page refresh/status must
    # never manufacture a check time. The allowlist lock serializes writers.
    jq -n --arg backend "$BACKEND" --arg section "$SECTION" --arg interface "$iface" \
      --arg time "$(date '+%Y-%m-%dT%H:%M:%S%z')" --arg epoch "$(date +%s)" \
      --arg monotonic "$(monotonic)" --arg boot "$(boot_id)" --arg result "$PROBE_CODE" --argjson code "$rc" \
      '{backend:$backend,section:$section,interface:$interface,time:$time,epoch:$epoch,
        monotonic:$monotonic,boot:$boot,result:$result,code:$code}' > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$STATE_DIR/last-check.json" || return 1
    cp "$STATE_DIR/last-check.json" "$STATE_DIR/check-$iface.json.$$" &&
      mv "$STATE_DIR/check-$iface.json.$$" "$STATE_DIR/check-$iface.json"
    if [ "$iface" = "$CURRENT" ]; then
        cp "$STATE_DIR/last-check.json" "$STATE_DIR/last-active-check.json.$$" &&
          mv "$STATE_DIR/last-active-check.json.$$" "$STATE_DIR/last-active-check.json"
    fi
}
promote_active_check() {
    local tmp="$STATE_DIR/last-active-check.json.$$"
    [ -r "$STATE_DIR/last-check.json" ] || return 0
    # A verified switch can make the most recently probed reserve current.
    # Promote its original timestamp; never invent a new probe at apply time.
    jq -ce --arg b "$BACKEND" --arg s "$SECTION" --arg i "$1" --arg boot "$(boot_id)" \
      'select(.backend==$b and .section==$s and .interface==$i and .boot==$boot and .code==0 and .result=="HEALTHY")' \
      "$STATE_DIR/last-check.json" > "$tmp" && mv "$tmp" "$STATE_DIR/last-active-check.json" || { rm -f "$tmp"; return 0; }
}
probe_interface() {
    local rc
    probe_interface_impl "$1"; rc=$?
    record_check "$1" "$rc" || :
    return "$rc"
}
candidate_is_healthy() {
    local iface="$1" n=0
    while [ "$n" -lt "$CANDIDATE_SUCCESS_THRESHOLD" ]; do
        probe_interface "$iface" || return $?
        n=$((n + 1))
    done
}

# A healthy engine is a live procd instance using exactly this configuration,
# not just an init script returning success or a stale JSON file.
runtime_pid() {
    local data pid cmd
    data="$(ubus call service list '{"name":"sing-box"}' 2>/dev/null)" || return 1
    # Keep the argv pairing explicit: another service/config must never qualify.
    pid="$(printf '%s' "$data" | jq -er --arg c "$SING_BOX_CONFIG" \
        '[.["sing-box"].instances[]? | select(.running == true) |
          select(.command as $v | any(range(0; ($v|length)-1); ($v[.] == "-c" or $v[.] == "--config") and $v[.+1] == $c)) | .pid] |
          select(length == 1) | .[0]' 2>/dev/null)" || return 1
    number "$pid" && kill -0 "$pid" 2>/dev/null || return 1
    cmd="$(tr '\000' '\n' < "/proc/$pid/cmdline" 2>/dev/null)"
    case "$(printf '%s\n' "$cmd" | head -n1)" in */sing-box|sing-box) ;; *) return 1;; esac
    printf '%s\n' "$cmd" | grep -Fxq "$SING_BOX_CONFIG" || return 1
    [ -r "$SING_BOX_CONFIG" ] || return 1
    printf '%s\n' "$pid"
}
podkop_runtime_ready() { runtime_pid >/dev/null; }
runtime_healthy() {
    podkop_runtime_ready || { REASON=RUNTIME_DOWN; return 1; }
    verify_path "$1"
}

outbound_tag() {
    local label
    if [ "$BACKEND" = forkop ]; then
        label="$(uci -q get "forkop.$SECTION.label" 2>/dev/null)"
        printf '%s\n' "${label:-$SECTION}"
    else printf '%s-out\n' "$SECTION"; fi
}
verify_podkop_binding() {
    local iface="$1" tag
    tag="$(outbound_tag)"
    jq -e --arg tag "$tag" --arg iface "$iface" '
      .outbounds as $all |
      def leaf($t; $depth):
        if $depth > 4 then false else
        [$all[] | select(.tag == $t)] as $a |
        if ($a|length) != 1 then false else $a[0] as $o |
        if $o.type == "direct" then $o.bind_interface == $iface and (($o.detour // "") == "")
        elif $o.type == "selector" and ($o.outbounds|length) == 1 then leaf($o.outbounds[0]; $depth+1)
        else false end end end;
      leaf($tag; 0)' "$SING_BOX_CONFIG" >/dev/null 2>&1
}
backend_reload() {
    case "$BACKEND" in forkozz) bounded 60 /usr/bin/netshift reload;; *) bounded 60 "$PODKOP_INIT" reload;; esac
}
adapter_apply() {
    adapter apply
}
backend_applying() {
    local data
    # Podkop/NetShift init start returns after procd registration, while its
    # one-shot /usr/bin/<backend> start may still be generating configuration.
    # A long-lived Forkop watcher is not a generation job.
    case "$BACKEND" in podkop|forkozz) ;; *) return 1;; esac
    data="$(ubus call service list "{\"name\":\"$CONFIG_PACKAGE\"}" 2>/dev/null)" || return 1
    [ -n "$data" ] || return 1
    printf '%s' "$data" |
      jq -e --arg p "$CONFIG_PACKAGE" --arg cmd "/usr/bin/$CONFIG_PACKAGE" \
        '.[$p].instances // {} | any(.[]; .running == true and .command[0] == $cmd and .command[1] == "start")' >/dev/null 2>&1
}
wait_backend_applied() {
    local n=0
    while [ "$n" -lt "$RUNTIME_WAIT" ]; do
        remaining >/dev/null && config_unchanged || return 3
        # Allow procd to fork its registered child before concluding that the
        # one-shot completed. Then require BOTH completion and new binding.
        if [ "$n" -ge 2 ] && ! backend_applying && verify_podkop_binding "$OWNED_TO"; then return 0; fi
        sleep 1; n=$((n + 1))
    done
    REASON=BACKEND_APPLY_TIMEOUT
    verify_podkop_binding "$OWNED_TO" || REASON=CONFIG_BINDING_INVALID
    return 1
}
ensure_started() {
    local until pid first_id n=0
    state STARTING_BACKEND
    [ "$START_ATTEMPTS" -lt 2 ] || { REASON=START_ATTEMPTS_EXHAUSTED; return 1; }
    START_ATTEMPTS=$((START_ATTEMPTS + 1))
    printf '%s\n' "$START_ATTEMPTS" > "$STATE_DIR/attempts"
    runtime_log_cursor || { REASON=RUNTIME_LOG_UNAVAILABLE; return 1; }
    # Native generation/lifecycle first. Do not start sing-box with old binding.
    adapter_apply || { diagnose_backend; return 1; }
    wait_backend_applied || return $?
    config_unchanged || return 3
    event BACKEND_STARTED
    verify_podkop_binding "$OWNED_TO" || { REASON=CONFIG_BINDING_INVALID; return 1; }
    bounded 10 sing-box check -c "$SING_BOX_CONFIG" || { REASON=CONFIG_INVALID; return 1; }
    until=$(( $(monotonic) + RUNTIME_WAIT ))
    [ "$until" -le "$DEADLINE" ] || until="$DEADLINE"
    # A backend normally starts its own engine; never duplicate that start.
    if ! podkop_runtime_ready; then
        n=$((START_ATTEMPTS + 1)); START_ATTEMPTS="$n"
        [ "$n" -le 2 ] || { REASON=START_ATTEMPTS_EXHAUSTED; return 1; }
        engine_start || { diagnose_backend; return 1; }
        event SINGBOX_STARTED
    fi
    while [ "$(monotonic)" -lt "$until" ]; do
        config_unchanged || return 3
        pid="$(runtime_pid)" && break
        sleep 1
    done
    [ -n "$pid" ] || { REASON=RUNTIME_DOWN; return 1; }
    first_id="$(identity "$pid")"
    state VERIFYING
    n=0
    while [ "$n" -lt "$STABLE_SECONDS" ]; do
        remaining >/dev/null && config_unchanged || return 3
        [ "$(runtime_pid)" = "$pid" ] && [ "$(identity "$pid")" = "$first_id" ] || { REASON=RUNTIME_CRASH; return 1; }
        sleep 1; n=$((n + 1))
    done
    runtime_no_fatal || return 1
}
engine_start() {
    # OpenWrt packages' sing-box.init reads only main.conffile/main.enabled.
    # If this native contract is absent, do not launch an unrelated instance.
    [ "$(uci -q get sing-box.main.conffile)" = "$SING_BOX_CONFIG" ] &&
    [ "$(uci -q get sing-box.main.enabled)" = 1 ] || { REASON=ENGINE_INIT_CONTRACT_UNSUPPORTED; return 2; }
    bounded 10 "$SING_BOX_INIT" start
}
runtime_log_cursor() {
    logread > "$OP_LOCK/logs.before" 2>/dev/null || return 1
    tail -n1 "$OP_LOCK/logs.before" > "$OP_LOCK/log.cursor"
}
runtime_no_fatal() {
    local cursor
    cursor="$(cat "$OP_LOCK/log.cursor")"
    # Native generation can emit more than 200 lines. Use the complete bounded
    # system ring; if its cursor really rotated out, fail closed as unavailable.
    REASON=RUNTIME_LOG_UNAVAILABLE
    logread > "$OP_LOCK/logs.after" 2>/dev/null || return 1
    if [ -n "$cursor" ]; then
        grep -Fxq "$cursor" "$OP_LOCK/logs.after" || return 1
        awk -v cursor="$cursor" '$0==cursor {seen=1; next} seen {print}' "$OP_LOCK/logs.after" > "$OP_LOCK/logs.new"
    else cp "$OP_LOCK/logs.after" "$OP_LOCK/logs.new"; fi
    if grep -Eiq '(sing-box|sing_box).*(FATAL|panic|crash)|procd.*sing-box.*(crash|exit)' "$OP_LOCK/logs.new"; then
        REASON=RUNTIME_FATAL; return 1
    fi
    REASON=""; return 0
}
diagnose_backend() {
    # Raw output remains private and is discarded. Only category is recorded.
    case "$REASON" in DEADLINE|PAUSED|OPERATION_CANCELLED|CONFIG_CHANGED_EXTERNALLY|ENGINE_INIT_CONTRACT_UNSUPPORTED) return 0;; esac
    REASON=BACKEND_FAILED
    grep -Eiq 'rule.?set' "$OP_LOCK/command-output" && REASON=RULESET_FAILURE
    grep -Eiq 'dns|resolve|lookup|doh' "$OP_LOCK/command-output" && REASON=DNS_FAILURE
    grep -Eiq 'unknown field|unsupported|deprecated' "$OP_LOCK/command-output" && REASON=CONFIG_COMPATIBILITY
    grep -Eiq 'parse|invalid config' "$OP_LOCK/command-output" && REASON=CONFIG_INVALID
}

# Prove the ACTUAL engine's selected outbound, never an independent --interface
# probe masquerading as section verification. Prefer a loopback mixed inbound
# only when an unconditional, exclusive rule binds it to this section. Otherwise
# use the running engine's loopback Clash API outbound delay endpoint.
verify_path() {
    local iface="$1" tag proxy host port rule api secret url result good=0
    verify_podkop_binding "$iface" || { REASON=CONFIG_BINDING_INVALID; return 1; }
    podkop_runtime_ready || { REASON=RUNTIME_DOWN; return 1; }
    nft list table inet "$NFT_TABLE" > "$OP_LOCK/command-output" 2>/dev/null || { REASON=NFT_RULES_MISSING; return 1; }
    grep -Eq '(tproxy|redirect|jump|vmap)' "$OP_LOCK/command-output" || { REASON=NFT_RULES_MISSING; return 1; }
    # Require the backend's policy route and rule, not an unrelated default.
    ip -4 rule show | grep -Eq "fwmark .*lookup $CONFIG_PACKAGE([[:space:]]|$)" || { REASON=POLICY_RULES_MISSING; return 1; }
    ip -4 route show table "$CONFIG_PACKAGE" | grep -Eq '^local (default|0\.0\.0\.0/0) dev lo' || { REASON=POLICY_ROUTE_MISSING; return 1; }
    tag="$(outbound_tag)"
    proxy="$(jq -er --arg t "$tag" '
      .route.rules as $r | [.inbounds[]? | select(.type == "mixed" and .listen == "127.0.0.1") |
        . as $i | [$r[]? | select((.inbound == $i.tag) or (.inbound|type == "array" and index($i.tag) != null))] as $matches |
        select(($matches|length)==1) | select($matches[0].outbound == $t) | select($r[0] == $matches[0]) |
        select(($matches[0]|keys - ["action","inbound","outbound"])|length == 0) |
        select((.users // [] | length)==0) | .listen_port] | .[0] // empty' "$SING_BOX_CONFIG" 2>/dev/null)"
    if number "$proxy" && [ "$proxy" -gt 0 ] && [ "$proxy" -le 65535 ]; then
        CURRENT_PROBE="$iface"; interface_state "$iface" || { REASON="$PROBE_CODE"; return 1; }
        https_targets "$DEVICE" "http://127.0.0.1:$proxy" || { REASON="PATH_$PROBE_CODE"; return 1; }
        return 0
    fi
    api="$(jq -er '.experimental.clash_api.external_controller // empty' "$SING_BOX_CONFIG" 2>/dev/null)"
    case "$api" in
        127.0.0.1:*) port="${api#*:}";;
        0.0.0.0:*) port="${api#*:}"; api="127.0.0.1:$port";;
        *:*)
            host="${api%:*}"; port="${api##*:}"
            # Existing API may bind the router's LAN address, not loopback.
            # Accept only a literal address actually assigned to THIS router.
            # No new listener or network access permission is created.
            printf '%s\n' "$host" | awk -F. 'NF!=4 {exit 1} {for(i=1;i<=4;i++)if($i!~/^[0-9]+$/||$i>255)exit 1}' || { REASON=PATH_TEST_UNAVAILABLE; return 2; }
            ip -4 -o addr show | awk -v h="$host" '{split($4,a,"/");if(a[1]==h)ok=1} END{exit !ok}' || { REASON=PATH_TEST_UNAVAILABLE; return 2; };;
        *) REASON=PATH_TEST_UNAVAILABLE; return 2;;
    esac
    number "$port" && [ "$port" -gt 0 ] && [ "$port" -le 65535 ] || { REASON=PATH_TEST_UNAVAILABLE; return 2; }
    secret="$(jq -r '.experimental.clash_api.secret // ""' "$SING_BOX_CONFIG")"
    tag="$(printf '%s' "$tag" | jq -sRr @uri)"
    # API delay invokes the named outbound inside the already running process.
    # First test an unrelated URL to guard APIs returning synthetic delay values.
    result="$(probe_curl -fsS --noproxy '*' -H "Authorization: Bearer $secret" \
      "http://$api/proxies/$tag/delay?timeout=2000&url=https%3A%2F%2Fvpn-failover.invalid%2F" 2>/dev/null)"
    printf '%s' "$result" | jq -e '.delay > 0' >/dev/null 2>&1 && { REASON=PATH_TEST_INVALID; return 2; }
    for url in 'https%3A%2F%2Fwww.cloudflare.com%2Fcdn-cgi%2Ftrace' 'https%3A%2F%2Fwww.msftconnecttest.com%2Fconnecttest.txt'; do
        remaining >/dev/null && config_unchanged || return 3
        result="$(probe_curl -fsS --noproxy '*' -H "Authorization: Bearer $secret" \
          "http://$api/proxies/$tag/delay?timeout=$((MAX_TIME * 1000 - 500))&url=$url" 2>/dev/null)" || continue
        printf '%s' "$result" | jq -e '.delay > 0' >/dev/null 2>&1 && good=$((good + 1))
    done
    [ "$good" -gt 0 ] || { REASON=PATH_HTTPS_FAILURE; return 1; }
}

adapter_set_interface() {
    adapter set_interface "$@"
}
guarded_set_interface() {
    local iface="$1"
    remaining >/dev/null && config_unchanged || return 3
    # Do not commit anyone's pending UCI transaction along with ours.
    [ -z "$(uci -q changes "$CONFIG_PACKAGE")" ] || { REASON=CONFIG_CHANGED_EXTERNALLY; return 3; }
    uci -q set "$INTERFACE_KEY=$iface" && uci -q commit "$CONFIG_PACKAGE" || { REASON=UCI_WRITE_FAILED; return 1; }
    EXPECTED_CONFIG="$(config_fingerprint)"
}
snapshot_operation() {
    uci -q export "$CONFIG_PACKAGE" > "$OP_LOCK/config.before" || return 1
    [ ! -r "$SING_BOX_CONFIG" ] || cp "$SING_BOX_CONFIG" "$OP_LOCK/runtime.before" || return 1
    { "$PODKOP_INIT" enabled >/dev/null 2>&1; echo "backend_enabled=$?"
      "$SING_BOX_INIT" enabled >/dev/null 2>&1; echo "engine_enabled=$?"; } > "$OP_LOCK/services.before"
}
verify_autostart() {
    local current
    current="$( { "$PODKOP_INIT" enabled >/dev/null 2>&1; echo "backend_enabled=$?"
      "$SING_BOX_INIT" enabled >/dev/null 2>&1; echo "engine_enabled=$?"; } )"
    [ "$current" = "$(cat "$OP_LOCK/services.before")" ] || { REASON=AUTOSTART_CHANGED; return 1; }
}
rollback_operation() {
    config_unchanged || { event CONFIG_CHANGED_EXTERNALLY; return 3; }
    [ -n "$OWNED_KEY" ] && [ "$OWNED_FROM" != "$OWNED_TO" ] || return 0
    [ "$(get_current_interface)" = "$OWNED_TO" ] || { REASON=CONFIG_CHANGED_EXTERNALLY; event CONFIG_CHANGED_EXTERNALLY; return 3; }
    state ROLLING_BACK
    adapter_set_interface "$OWNED_FROM" || return $?
    operation ROLLBACK "$OWNED_TO" "$OWNED_FROM" INTERFACE_ONLY
    # Generate via native lifecycle; never blindly copy the old config snapshot.
    OWNED_TO="$OWNED_FROM"
    if remaining >/dev/null && ensure_started && verify_path "$OWNED_FROM"; then event PATH_VERIFIED ROLLBACK_PATH_VERIFIED
    else event RECOVERY_FAILED ROLLBACK_NOT_HEALTHY; fi
    return 1
}
recover_interface() {
    local from="$1" target="$2" failure
    config_unchanged && [ "$(get_connection_type)" = vpn ] && [ "$(get_current_interface)" = "$from" ] || { REASON=CONFIG_CHANGED_EXTERNALLY; return 3; }
    OWNED_FROM="$from"; OWNED_TO="$target"; OWNED_KEY="$INTERFACE_KEY"
    snapshot_operation || { REASON=SNAPSHOT_FAILED; return 1; }
    START_ATTEMPTS=0
    if [ "$from" != "$target" ]; then
        candidate_is_healthy "$target" || { REASON="$PROBE_CODE"; return 1; }
        event CANDIDATE_HEALTHY "$PROBE_CODE endpoint=$ENDPOINT"
        state APPLYING
        adapter_set_interface "$target" || return $?
        event SWITCH_APPLIED
    fi
    if ensure_started && verify_path "$target" && verify_autostart && config_unchanged; then
        event PATH_VERIFIED
        state RECOVERED
        event RECOVERED
        promote_active_check "$target"
        printf '0\n' > "$FAIL_FILE"; printf '0\n' > "$STATE_DIR/runtime-failures"
        printf '%s\n' "$(( $(monotonic) + HOLD_SECONDS ))" > "$STATE_DIR/retry-at"
        printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$from" "$target" > "$LAST_SWITCH_FILE"
        printf '%s\n' "$EXPECTED_CONFIG" > "$STATE_DIR/confirmed-config"
        EXPECTED_CONFIG=""; return 0
    fi
    failure="${REASON:-RECOVERY_FAILED}"
    mark_quarantine "$target"
    rollback_operation || :
    state RECOVERY_FAILED "$failure"; event RECOVERY_FAILED
    return 1
}
mark_quarantine() { valid_name "$1" && printf '%s\n' "$(( $(monotonic) + QUARANTINE_SECONDS ))" > "$STATE_DIR/quarantine-$1"; }
is_quarantined() {
    local until
    until="$(cat "$STATE_DIR/quarantine-$1" 2>/dev/null)"
    number "$until" && [ "$(monotonic)" -lt "$until" ]
}
counter() { local v; v="$(cat "$1" 2>/dev/null)"; if number "$v"; then echo "$v"; else echo 0; fi; }
reset_counters() {
    printf '0\n' > "$FAIL_FILE"; printf '0\n' > "$STATE_DIR/runtime-failures"
    printf '0\n' > "$STATE_DIR/retry-at"
}
cycle() {
    local current rc runtime_rc failures runtime_failures retry candidate signature previous other table
    acquire_operation || return 2
    if ! select_backend; then state RECOVERY_FAILED "$BACKEND_ERROR"; release_operation; return 1; fi
    CURRENT="$(get_current_interface)"; current="$CURRENT"
    if ! recovery_allowed; then
        previous="$(cat "$STATE_DIR/state" 2>/dev/null)"
        state PAUSED
        [ "$previous" = PAUSED ] || event PAUSED
        release_operation; return 0
    fi
    for other in podkop forkop netshift; do
        [ "$other" != "$CONFIG_PACKAGE" ] || continue
        case "$other" in podkop) table=PodkopTable;; forkop) table=ForkopTable;; netshift) table=NetShiftTable;; esac
        if adapter_active "$other" "$table"; then state RECOVERY_FAILED OTHER_BACKEND_ACTIVE; release_operation; return 2; fi
    done
    if [ "$(get_connection_type)" != vpn ]; then state OBSERVING SECTION_NOT_VPN; release_operation; return 0; fi
    valid_name "$current" || { state RECOVERY_FAILED INVALID_INTERFACE; release_operation; return 1; }
    signature="$BACKEND:$SECTION:$INTERFACE_KEY:$current:$(get_connection_type)"
    previous="$(cat "$STATE_DIR/selection" 2>/dev/null)"
    if [ -n "$previous" ] && [ "$signature" != "$previous" ]; then
        reset_counters; event CONFIG_CHANGED_EXTERNALLY SELECTION_CHANGED
    fi
    printf '%s\n' "$signature" > "$STATE_DIR/selection"
    EXPECTED_CONFIG="$(config_fingerprint)"
    retry="$(counter "$STATE_DIR/retry-at")"
    if [ "$(monotonic)" -lt "$retry" ]; then
        # Preserve the last confirmed result during hold/cooldown.
        release_operation; return 0
    fi
    state PROBING
    probe_interface "$current"; rc=$?
    if ! config_unchanged; then state RECOVERY_FAILED CONFIG_CHANGED_EXTERNALLY; event CONFIG_CHANGED_EXTERNALLY; release_operation; return 3; fi
    if [ "$rc" = 2 ]; then
        # A dead tunnel cannot bootstrap DNS. Try allowed reserves independently
        # to seed the short-lived target cache, then retest current with known
        # addresses. This does not count a DNS outage as a VPN failure.
        for candidate in $(discover_interfaces); do
            [ "$candidate" != "$current" ] || continue
            is_quarantined "$candidate" && continue
            remaining >/dev/null && config_unchanged || break
            if candidate_is_healthy "$candidate"; then probe_interface "$current"; rc=$?; break; fi
        done
    fi
    if [ "$rc" = 2 ]; then
        state WAITING_NETWORK "$PROBE_CODE"
        # An infrastructure/control failure is not evidence the VPN failed.
        printf '%s\n' "$(( $(monotonic) + NO_RESERVE_RETRY_INTERVAL ))" > "$STATE_DIR/retry-at"
        release_operation; return 2
    fi
    if [ "$rc" = 0 ]; then
        runtime_healthy "$current"; runtime_rc=$?
        if [ "$runtime_rc" = 0 ]; then
            # No UCI/service changes for a healthy path. Both kinds of failure
            # evidence may be cleared only after this actual section-path test.
            if ! config_unchanged; then
                state RECOVERY_FAILED CONFIG_CHANGED_EXTERNALLY; event CONFIG_CHANGED_EXTERNALLY
                release_operation; return 3
            fi
            reset_counters; printf '%s\n' "$EXPECTED_CONFIG" > "$STATE_DIR/confirmed-config"
            state OBSERVING; release_operation; return 0
        fi
        if [ "$runtime_rc" = 2 ]; then
            # Missing verification support is not a backend failure; do not
            # repeatedly reload an otherwise live engine to manufacture proof.
            state VERIFYING "${REASON:-PATH_TEST_UNAVAILABLE}"
            printf '%s\n' "$(( $(monotonic) + NO_RESERVE_RETRY_INTERVAL ))" > "$STATE_DIR/retry-at"
            release_operation; return 2
        fi
        event RUNTIME_DOWN "${REASON:-RUNTIME_NOT_READY}"
        runtime_failures="$(counter "$STATE_DIR/runtime-failures")"
        printf '%s\n' "$((runtime_failures + 1))" > "$STATE_DIR/runtime-failures"
        recover_interface "$current" "$current"; rc=$?
    else
        failures="$(counter "$FAIL_FILE")"; failures=$((failures + 1))
        printf '%s\n' "$failures" > "$FAIL_FILE"
        event CURRENT_FAILED "$PROBE_CODE $failures/$FAIL_THRESHOLD"
        if [ "$failures" -lt "$FAIL_THRESHOLD" ]; then state OBSERVING "$PROBE_CODE"; release_operation; return 1; fi
        rc=1
        for candidate in $(discover_interfaces); do
            [ "$candidate" != "$current" ] || continue
            is_quarantined "$candidate" && continue
            remaining >/dev/null && config_unchanged || break
            candidate_is_healthy "$candidate" || continue
            recover_interface "$current" "$candidate"; rc=$?
            # At most one apply/recovery per cycle; no candidate ping-pong.
            break
        done
        if ! config_unchanged; then
            rc=3; state RECOVERY_FAILED "${REASON:-CONFIG_CHANGED_EXTERNALLY}"; event CONFIG_CHANGED_EXTERNALLY
        elif [ "$rc" != 0 ] && [ -z "$OWNED_KEY" ]; then state NO_HEALTHY_RESERVE; event NO_HEALTHY_RESERVE; fi
    fi
    if [ "$rc" != 0 ]; then printf '%s\n' "$(( $(monotonic) + NO_RESERVE_RETRY_INTERVAL ))" > "$STATE_DIR/retry-at"; fi
    release_operation
    return "$rc"
}

run_daemon() {
    local started owner
    ensure_state_dir || return 1
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        owner="$(cat "$PID_FILE" 2>/dev/null)"
        number "$owner" && [ "$(identity "$owner")" = "$(cat "$STATE_DIR/daemon-identity" 2>/dev/null)" ] && { say DAEMON_ALREADY_RUNNING >&2; return 2; }
        # An incomplete lock is left for explicit administrative recovery.
        number "$owner" || return 2
        rm -f "$PID_FILE"
        rmdir "$LOCK_DIR" && mkdir "$LOCK_DIR" || return 2
    fi
    printf '%s\n' "$$" > "$PID_FILE"
    identity "$$" > "$STATE_DIR/daemon-identity"
    DAEMON_MODE=1
    trap 'cleanup_daemon_local; exit 0' TERM INT HUP
    # procd owns daemon lifetime; operations from all entry points share OP_LOCK.
    started="$(monotonic)"
    while :; do
        if [ "$(( $(monotonic) - started ))" -ge "$STARTUP_GRACE_PERIOD" ]; then cycle || :; fi
        sleep "$CHECK_INTERVAL"
    done
}
pause_control() {
    local value="$1"
    # Persist immediately even during a running operation. That operation sees
    # the changed fingerprint/pause and aborts without overwriting user choices.
    [ -z "$(uci -q changes vpn_failover)" ] || { say CONFIG_CHANGED_EXTERNALLY; return 3; }
    uci -q get vpn_failover.main >/dev/null 2>&1 || uci -q set vpn_failover.main=settings || return 1
    uci -q set "vpn_failover.main.paused=$value" && uci -q commit vpn_failover || return 1
    backend_line "paused=$value"
}
show_test() {
    local iface rc=0 overall=0
    acquire_operation || { backend_line BUSY; return 2; }
    CURRENT="$(get_current_interface)"
    for iface in $(tunnel_inventory "$CURRENT"); do
        probe_interface "$iface"; rc=$?
        [ "$rc" = 0 ] || overall=1
        backend_line "$iface: $PROBE_CODE"
        remaining >/dev/null || { overall=1; break; }
    done
    release_operation
    return "$overall"
}
show_status() {
    show_dashboard | jq -r '
      ("[" + .backend_label + "] ") as $p |
      $p + "Текущий обход: " + .backend_label,
      $p + "Секция: " + .section,
      $p + "Служба Failover: " + (if .running then "работает" else "остановлена" end),
      $p + "Служба/правила обхода: " + (if .backend_active then "обнаружены" else "не обнаружены" end),
      $p + "sing-box: " + (if .runtime then "работает" else "остановлен или конфигурация не подтверждена" end),
      $p + "Работоспособность обхода: " + (if .ready and .check_fresh then "подтверждена последней проверкой" else "не подтверждена" end),
      $p + "Активный туннель: " + (if .current == "" then "не выбран" else .current end),
      $p + "Последняя проверка активного туннеля: " + (.last_active_check.time // "ещё не выполнялась"),
      $p + "Результат проверки: " + (.last_active_check.result // "нет данных"),
      $p + "Состояние: " + .state + (if .reason == "" then "" else " / " + .reason end),
      (if .error == "" then empty else $p + "Ошибка: " + .error end)'
}
show_dashboard() {
    local error="" runtime=false paused=false enabled=false running=false ready=false state reason runtime_reason
    local backend_installed=false backend_active=false last_check last_active_check age=-1 check_fresh=false current
    select_backend || error="$BACKEND_ERROR"
    podkop_runtime_ready && runtime=true
    paused && paused=true
    "$INIT_SERVICE" enabled >/dev/null 2>&1 && enabled=true
    "$INIT_SERVICE" running >/dev/null 2>&1 && running=true
    current="$(get_current_interface)"
    local iface tunnel_checks
    tunnel_checks="$(for iface in $(tunnel_inventory "$current"); do
        jq -nc --arg i "$iface" --arg b "$BACKEND" --arg s "$SECTION" '
          ([inputs | select(.interface==$i and .backend==$b and .section==$s)] | first)
          // {interface:$i}' "$STATE_DIR/check-$iface.json" 2>/dev/null ||
          jq -nc --arg i "$iface" '{interface:$i}'
    done | jq -sc .)"
    if [ -n "$BACKEND" ] && [ -z "$error" ]; then
        [ ! -x "$PODKOP_INIT" ] || backend_installed=true
        adapter detect && backend_active=true
    fi
    last_check="$(jq -ce 'select(type == "object")' "$STATE_DIR/last-check.json" 2>/dev/null)"
    last_active_check="$(jq -ce --arg b "$BACKEND" --arg s "$SECTION" --arg i "$current" --arg boot "$(boot_id)" \
      'select(.backend == $b and .section == $s and .interface == $i and .boot == $boot)' "$STATE_DIR/last-active-check.json" 2>/dev/null)"
    if [ -n "$last_active_check" ]; then
        age="$(printf '%s' "$last_active_check" | jq -r '.monotonic // ""')"
        if number "$age"; then age=$(( $(monotonic) - age )); else age=-1; fi
        [ "$age" -lt 0 ] || [ "$age" -gt "$((CHECK_INTERVAL + OP_LIMIT + 15))" ] || check_fresh=true
    fi
    state="$(cat "$STATE_DIR/state" 2>/dev/null)"; state="${state:-OBSERVING}"
    reason="$(cat "$STATE_DIR/reason" 2>/dev/null)"
    [ "$paused" != true ] || state=PAUSED
    if { [ "$state" = RECOVERED ] || { [ "$state" = OBSERVING ] && [ -z "$reason" ]; }; } && \
       [ "$runtime" = true ] && [ "$paused" = false ] && [ -z "$error" ] && \
       [ "$(cat "$STATE_DIR/confirmed-config" 2>/dev/null)" = "$(config_fingerprint)" ]; then ready=true; fi
    if [ "$check_fresh" != true ] || ! printf '%s' "${last_active_check:-null}" | jq -e '.code==0 and .result=="HEALTHY"' >/dev/null 2>&1; then ready=false; fi
    runtime_reason=PROCESS_OR_CONFIG_UNAVAILABLE; [ "$runtime" != true ] || runtime_reason=RUNNING
    { [ ! -r "$HISTORY_FILE" ] || cat "$HISTORY_FILE"; } | jq -Rn \
      --arg backend "$BACKEND" --arg backend_label "$(backend_label)" --arg section "$SECTION" --arg current "$current" --arg error "$error" \
      --argjson backend_installed "$backend_installed" --argjson backend_active "$backend_active" \
      --argjson last_check "${last_check:-null}" --argjson last_active_check "${last_active_check:-null}" \
      --argjson check_fresh "$check_fresh" --argjson check_age "$age" \
      --argjson tunnel_checks "${tunnel_checks:-[]}" \
      --arg state "$state" --arg reason "$reason" --arg deadline "$(cat "$STATE_DIR/deadline" 2>/dev/null)" \
      --arg retry "$(cat "$STATE_DIR/retry-at" 2>/dev/null)" --arg op "$(cat "$OP_LOCK/pid" 2>/dev/null)" \
      --arg operation_id "$(cat "$OP_LOCK/id" 2>/dev/null)" --arg probing "$(cat "$STATE_DIR/probing" 2>/dev/null)" \
      --arg attempts "$(counter "$STATE_DIR/attempts")" --arg runtime_reason "$runtime_reason" \
      --arg last_switch "$(cat "$LAST_SWITCH_FILE" 2>/dev/null)" \
      --argjson runtime "$runtime" --argjson paused "$paused" --argjson running "$running" --argjson enabled "$enabled" --argjson ready "$ready" \
      --arg failures "$(counter "$FAIL_FILE")" --arg runtime_failures "$(counter "$STATE_DIR/runtime-failures")" \
      '{backend:$backend,backend_label:$backend_label,backend_installed:$backend_installed,backend_active:$backend_active,
        last_check:$last_check,last_active_check:$last_active_check,check_fresh:$check_fresh,last_check_age_seconds:$check_age,tunnel_checks:$tunnel_checks,
        section:$section,current:$current,error:$error,state:$state,reason:$reason,runtime:$runtime,paused:$paused,
        running:$running,enabled:$enabled,ready:$ready,deadline_monotonic:$deadline,retry_monotonic:$retry,operation_pid:$op,
        installed:true,operation_id:$operation_id,probing:$probing,attempts:$attempts,runtime_reason:$runtime_reason,last_confirmed_switch:$last_switch,
        awg_failures:$failures,runtime_failures:$runtime_failures,
        events:([inputs | split("\t") | select(length == 8) |
          {time:.[0],backend:.[1],section:.[2],event:.[3],from:.[4],to:.[5],detail:.[6],epoch:.[7]}] | reverse)}'
}
show_config_data() {
    printf 'VERSION=%s\nBACKEND=%s\nSECTION=%s\nCHECK_INTERVAL=%s\nFAIL_THRESHOLD=%s\nCANDIDATE_SUCCESS_THRESHOLD=%s\nSTARTUP_GRACE_PERIOD=%s\nNO_RESERVE_RETRY_INTERVAL=%s\nOP_LIMIT=%s\nRUNTIME_WAIT=%s\nHOLD_SECONDS=%s\n' \
      "$VERSION" "$BACKEND" "$SECTION" "$CHECK_INTERVAL" "$FAIL_THRESHOLD" "$CANDIDATE_SUCCESS_THRESHOLD" "$STARTUP_GRACE_PERIOD" "$NO_RESERVE_RETRY_INTERVAL" "$OP_LIMIT" "$RUNTIME_WAIT" "$HOLD_SECONDS"
    printf 'PAUSED=%s\nRECOVERY_ENABLED=%s\nALLOWED_INTERFACES=%s\n' \
      "$(if paused; then echo 1; else echo 0; fi)" \
      "$(if [ "$(setting recovery_enabled)" = 0 ]; then echo 0; else echo 1; fi)" "$(discover_interfaces | tr '\n' ' ')"
}
show_config() {
    show_config_data | while IFS= read -r line; do backend_line "$line"; done
}
load_settings
