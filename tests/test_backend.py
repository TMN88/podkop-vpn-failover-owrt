"""Run the actual worker functions with mocked UCI/services; no router needed."""
import os
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
shell = os.environ.get('TEST_SHELL') or shutil.which('sh')
if not shell:
    raise SystemExit('Set TEST_SHELL to a POSIX sh executable')
source = (root / 'podkop-vpn-failover').read_text(encoding='utf-8').split('\nselect_backend || :\n\ncase ')[0]
harness = r'''
PATH=/usr/bin:$PATH
die() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || die "$1 != $2 ($3)"; }
cfg_backend=auto; cfg_section=main; have_podkop=1; have_netshift=0
cfg_iface=awg0; mode=vpn; disabled=1; commit_fail=0
uci() {
    [ "$1" != -q ] || shift
    case "$1:$2" in
        get:vpn_failover.main.backend) echo "$cfg_backend" ;;
        get:vpn_failover.main.section) echo "$cfg_section" ;;
        get:podkop.main) [ "$have_podkop" = 1 ] && echo section ;;
        get:netshift.settings) [ "$have_netshift" = 1 ] && echo settings ;;
        get:netshift.main|get:netshift.work) [ "$have_netshift" = 1 ] && echo section ;;
        get:*.connection_type) echo "$mode" ;;
        get:*.interface) echo "$cfg_iface" ;;
        get:*.enabled) echo "$disabled" ;;
        get:*.disabled) echo "${cfg_disabled:-0}" ;;
        set:*.interface=*) cfg_iface="${2#*=}" ;;
        commit:*) [ "$commit_fail" = 0 ] ;;
        *) return 1 ;;
    esac
}
select_backend || die podkop_detection
assert_eq "$BACKEND" podkop auto
have_podkop=0; have_netshift=1
select_backend || die forkozz_detection
assert_eq "$CONFIG_PACKAGE" netshift package
assert_eq "$PODKOP_INIT" /etc/init.d/netshift service
have_podkop=1
if select_backend; then die ambiguous_auto; fi
cfg_backend=forkozz; cfg_section=work
select_backend || die explicit
assert_eq "$SECTION" work section
cfg_section='main;echo_bad'
if select_backend; then die unsafe_section; fi
cfg_section=missing
if select_backend; then die missing_section; fi
cfg_section=work; select_backend || die select
mode=proxy
assert_eq "$(get_connection_type)" proxy proxy_mode
mode=vpn; disabled=0
if get_connection_type >/dev/null; then die disabled_section; fi
disabled=1
assert_eq "$(get_connection_type)" vpn vpn_mode
cfg_disabled=1
if get_connection_type >/dev/null; then die netshift_disabled; fi
cfg_disabled=0
logger() { :; }
sleep() { :; }
POST_SWITCH_DELAY=0
STATE_DIR="$TEST_STATE"; HISTORY_FILE="$STATE_DIR/operations.tsv"; LAST_SWITCH_FILE="$STATE_DIR/last-switch"
if [ -n "${TEST_JQ:-}" ]; then jq() { "$TEST_JQ" "$@"; }; fi
command -v jq >/dev/null 2>&1 || die jq_required_for_json_tests
SING_BOX_CONFIG="$TEST_STATE/runtime.json"
set -e
log_msg notice 'Log succeeds in a set -e caller with foreground output disabled'
set +e
printf '%s\n' '{"outbounds":[{"type":"direct","tag":"work-out","bind_interface":"awg0"},{"type":"direct","tag":"main-out","bind_interface":"awg9"}]}' > "$SING_BOX_CONFIG"
verify_podkop_binding awg0 || die runtime_binding
cfg_iface=awg9
if verify_podkop_binding awg9; then die wrong_section_binding; fi
cfg_iface=awg0
printf '%s\n' '{"outbounds":[{"type":"direct","tag":"work-out","bind_interface":"wrong"}]}' > "$SING_BOX_CONFIG"
if verify_podkop_binding awg0; then die stale_runtime; fi
backend_reload() { [ "${reload_fail:-0}" = 0 ]; }
verify_podkop_binding() { [ "${binding_fail:-0}" = 0 ]; }
candidate_is_healthy() { [ "${health_fail:-0}" = 0 ]; }
clear_quarantine() { :; }; mark_quarantine() { :; }
switch_to_interface awg0 awg1 || die successful_switch
assert_eq "$cfg_iface" awg1 switched
grep -q 'success' "$HISTORY_FILE" || die success_history
cfg_iface=awg0; health_fail=1
if switch_to_interface awg0 awg2; then die unhealthy_candidate; fi
assert_eq "$cfg_iface" awg0 rollback
grep -q 'rollback' "$HISTORY_FILE" || die rollback_history
health_fail=0; reload_fail=1; cfg_iface=awg0
switch_to_interface awg0 awg3; rc=$?
assert_eq "$rc" 2 rollback_failure_stops_scan
grep -q 'rollback_failed' "$HISTORY_FILE" || die rollback_failure_history
reload_fail=0; cfg_iface=external
switch_to_interface awg0 awg4; rc=$?
assert_eq "$rc" 2 external_change
assert_eq "$cfg_iface" external preserve_external
cfg_iface=awg0; mode=proxy
switch_to_interface awg0 awg5; rc=$?
assert_eq "$rc" 2 preserve_mode
assert_eq "$cfg_iface" awg0 preserve_mode_cfg_iface
mode=vpn; cfg_backend=podkop; cfg_section=main; select_backend || die select_podkop
switch_to_interface awg0 awg6 || die podkop_regression
assert_eq "$cfg_iface" awg6 podkop_switch
HISTORY_LIMIT=3
operation notice a b 'one'
operation notice a b 'two'
operation notice a b 'three'
operation notice a b 'four'
assert_eq "$(wc -l < "$HISTORY_FILE" | tr -d ' ')" 3 history_bound
operation notice a b "$(printf 'injected\tfield\nnewline')"
awk -F '\t' 'NF != 8 { exit 1 }' "$HISTORY_FILE" || die tsv_injection
show_dashboard > "$TEST_STATE/dashboard.json"
jq -e '.events | length == 3' "$TEST_STATE/dashboard.json" >/dev/null || die dashboard_count
jq -e '.events[0].detail == "injected field newline"' "$TEST_STATE/dashboard.json" >/dev/null || die dashboard_escape
jq -e '.backend == "podkop" and .current == "awg6"' "$TEST_STATE/dashboard.json" >/dev/null || die dashboard_state
echo 'PASS: backend detection, sections, disabled/proxy guard, Podkop/Forkozz switch, rollback, external change, history bound and escaping'
'''
# Preserve test artifacts. No cleanup or deletion of user files.
state = root / 'test-output' / str(os.getpid())
state.mkdir(parents=True, exist_ok=True)
env = os.environ.copy()
env['TEST_STATE'] = state.as_posix()
busybox = os.environ.get('TEST_BUSYBOX')
if os.name == 'nt' and not busybox:
    env['TEST_STATE'] = '/' + env['TEST_STATE'][0].lower() + env['TEST_STATE'][2:]
argv = [busybox, 'sh'] if busybox else [shell]
result = subprocess.run(argv, input=source+'\n'+harness, text=True, encoding='utf-8', env=env)
raise SystemExit(result.returncode)
