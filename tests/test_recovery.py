"""Execute the production ash functions against deterministic local fixtures.

No router, administrator access, external DNS, or network access is used.
"""
import os
from pathlib import Path
import shutil
import subprocess
import re

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'test-output' / ('recovery-' + str(os.getpid()))
OUT.mkdir(parents=True, exist_ok=True)
busybox = os.environ.get('TEST_BUSYBOX')
shell = os.environ.get('TEST_SHELL') or shutil.which('sh')
argv = [busybox, 'sh'] if busybox else [shell]
jq = os.environ.get('TEST_JQ') or shutil.which('jq')
if not jq:
    raise SystemExit('Install jq or set TEST_JQ to its executable path')
jq = jq.replace('\\', '/')
header = (ROOT / 'podkop-vpn-failover').read_text(encoding='utf-8').split('RECOVERY_LIB=')[0]
lib = (ROOT / 'recovery.sh').read_text(encoding='utf-8').removesuffix('load_settings\n')
setup = r'''
die() { echo "FAIL $*" >&2; exit 1; }
eq() { [ "$1" = "$2" ] || die "$1 != $2 ($3)"; }
T=1000
monotonic() { echo "$T"; }
boot_id() { echo fixture-boot; }
identity() { [ "$1" = "$$" ] && echo 100; }
trusted_directory() { return 0; }
sleep() { :; }
backend_choice=podkop; cfg_section=main; cfg_iface=DE_custom
cfg_mode=vpn; cfg_paused=0; cfg_recovery=1; cfg_revision=1
cfg_pool='DE_custom NL_2 SE_vpn'; cfg_enabled=1
child_count=0; legacy_field=interface
active_podkop=1; active_forkop=0; active_netshift=0
uci() {
    [ "$1" != -q ] || shift
    case "$1:$2" in
        get:vpn_failover.main.backend) echo "$backend_choice";;
        get:vpn_failover.main.section) echo "$cfg_section";;
        get:vpn_failover.main.paused) echo "$cfg_paused";;
        get:vpn_failover.main.recovery_enabled) echo "$cfg_recovery";;
        get:vpn_failover.main.interfaces) echo "$cfg_pool";;
        get:*.settings.config_path) echo /etc/sing-box/config.json;;
        get:podkop.main|get:netshift.main|get:forkop.main) echo section;;
        get:*.enabled) echo "$cfg_enabled";;
        get:*.disabled) echo 0;;
        get:*.connection_type) echo "$cfg_mode";;
        get:forkop.main.action) echo "${forkop_action:-vpn}";;
        get:forkop.main.name) echo 'Main VPN';;
        get:sing-box.main.conffile) echo "$SING_BOX_CONFIG";;
        get:sing-box.main.enabled) echo 1;;
        get:forkop.main.section_interface|get:forkop.main.interfaces|get:forkop.main.interface)
            [ "${2##*.}" = "$legacy_field" ] && echo "$cfg_iface";;
        get:forkop.child1.name|get:forkop.child2.name) echo "$cfg_iface";;
        get:forkop.child1.section|get:forkop.child2.section) echo main;;
        get:*.interface) echo "$cfg_iface";;
        get:network.*.proto) echo amneziawg;;
        show:forkop)
            [ "$child_count" -lt 1 ] || echo forkop.child1=section_interface
            [ "$child_count" -lt 2 ] || echo forkop.child2=section_interface
            return 0;;
        changes:*) return 0;;
        export:*) printf '%s\n' "$cfg_revision:$cfg_iface:$cfg_paused:$cfg_mode:$backend_choice";;
        set:*.interface=*|set:*.name=*|set:*.interfaces=*|set:*.section_interface=*) cfg_iface="${2#*=}"; cfg_revision=$((cfg_revision+1));;
        commit:*) return 0;;
        *) return 1;;
    esac
}
adapter_active() { case "$1" in podkop) [ "$active_podkop" = 1 ];; forkop) [ "$active_forkop" = 1 ];; netshift) [ "$active_netshift" = 1 ];; esac; }
STATE_DIR="$TEST_STATE"; OP_LOCK="$STATE_DIR.operation"
FAIL_FILE="$STATE_DIR/failures"; HISTORY_FILE="$STATE_DIR/operations.tsv"; LAST_SWITCH_FILE="$STATE_DIR/last-switch"
ensure_state_dir
cleanup_routes() { :; }
select_backend || die select
probe_interface() {
    printf '%s\n' "$1" >> "$STATE_DIR/probes"
    PROBE_CODE=HEALTHY; ENDPOINT='203.0.113.10:443'
    case "$1" in
        DE_custom) if [ "${main_unknown:-0}" = 1 ]; then PROBE_CODE=DNS_FAILURE; return 2; fi
                   [ "${main_bad:-0}" = 0 ] || { PROBE_CODE=NO_HANDSHAKE; return 1; };;
        NL_2) [ "${reserve_bad:-0}" = 0 ] || { PROBE_CODE=HTTPS_FAILURE; return 1; };;
        SE_vpn) [ "${reserve_bad:-0}" = 0 ] || { PROBE_CODE=HTTPS_FAILURE; return 1; };;
    esac
}
runtime=1
podkop_runtime_ready() { [ "$runtime" = 1 ]; }
runtime_healthy() { podkop_runtime_ready; }
snapshot_operation() { :; }
ensure_started() {
    echo "$cfg_iface" >> "$STATE_DIR/starts"
    [ "${apply_bad:-0}" = 0 ] || { REASON=RULESET_FAILURE; return 1; }
    runtime=1
}
verify_autostart() { :; }
verify_path() {
    echo "$1" >> "$STATE_DIR/paths"
    [ "${path_bad:-0}" = 0 ] || { REASON=PATH_HTTPS_FAILURE; return 1; }
}
'''

CASES = {
    'healthy_no_service_changes': r'''
cycle || die cycle
[ ! -e "$STATE_DIR/starts" ] || die unnecessary_start
eq "$(cat "$STATE_DIR/probes")" DE_custom
eq "$cfg_iface" DE_custom
''',
    'stopped_runtime_still_probes_and_switches': r'''
runtime=0; main_bad=1; FAIL_THRESHOLD=3
cycle; cycle; cycle || die recover
eq "$cfg_iface" NL_2
eq "$runtime" 1
eq "$(cat "$FAIL_FILE")" 0
eq "$(cat "$STATE_DIR/state")" RECOVERED
grep -q CURRENT_FAILED "$HISTORY_FILE" || die missing_failure
grep -q PATH_VERIFIED "$HISTORY_FILE" || die missing_path
grep -q RECOVERED "$HISTORY_FILE" || die missing_recovery
eq "$(wc -l < "$STATE_DIR/starts" | tr -d ' ')" 1 no_duplicate
''',
    'runtime_down_healthy_awg_same_tunnel': r'''
runtime=0
cycle || die recovery
eq "$cfg_iface" DE_custom
eq "$(cat "$STATE_DIR/starts")" DE_custom
grep -q RUNTIME_DOWN "$HISTORY_FILE" || die event
! grep -q SWITCH_APPLIED "$HISTORY_FILE" || die changed_healthy_awg
''',
    'pause_and_proxy_never_probe_or_start': r'''
runtime=0; cfg_paused=1
cycle || die pause
eq "$(cat "$STATE_DIR/state")" PAUSED
[ ! -f "$STATE_DIR/probes" ] || die paused_probe
cfg_paused=0; cfg_mode=proxy
cycle || die proxy
[ ! -f "$STATE_DIR/starts" ] || die proxy_start
[ ! -f "$STATE_DIR/probes" ] || die proxy_probe
''',
    'unknown_not_vpn_failure_and_cooldown': r'''
main_unknown=1
cycle
[ ! -f "$FAIL_FILE" ] || die counted_infrastructure
eq "$(cat "$STATE_DIR/state")" WAITING_NETWORK
count="$(wc -l < "$STATE_DIR/probes")"
cycle
eq "$(wc -l < "$STATE_DIR/probes")" "$count" storm
''',
    'no_reserve_preserves_counter_no_storm': r'''
main_bad=1; reserve_bad=1; FAIL_THRESHOLD=1
cycle
eq "$(cat "$STATE_DIR/state")" NO_HEALTHY_RESERVE
eq "$(cat "$FAIL_FILE")" 1
count="$(wc -l < "$STATE_DIR/probes")"
cycle
eq "$(wc -l < "$STATE_DIR/probes")" "$count" no_storm
''',
    'ruleset_failure_rolls_back_only_interface_no_success': r'''
main_bad=1; runtime=0; FAIL_THRESHOLD=1; apply_bad=1
cycle
eq "$cfg_iface" DE_custom rollback
eq "$(cat "$STATE_DIR/state")" RECOVERY_FAILED
grep -q RULESET_FAILURE "$HISTORY_FILE" || die diagnose
grep -q ROLLBACK "$HISTORY_FILE" || die rollback
! grep -q $'\tRECOVERED\t' "$HISTORY_FILE" || die false_success
eq "$(cat "$FAIL_FILE")" 1 preserve_failure
''',
    'actual_path_failure_not_success': r'''
main_bad=1; FAIL_THRESHOLD=1; path_bad=1
cycle
eq "$cfg_iface" DE_custom
eq "$(cat "$STATE_DIR/state")" RECOVERY_FAILED
! grep -q $'\tRECOVERED\t' "$HISTORY_FILE" || die awg_only_success
''',
    'external_change_cancels_without_rollback': r'''
main_bad=1; FAIL_THRESHOLD=1
ensure_started() { cfg_iface=SE_vpn; cfg_revision=$((cfg_revision+1)); REASON=CONFIG_CHANGED_EXTERNALLY; return 1; }
cycle
eq "$cfg_iface" SE_vpn external_selection_preserved
grep -q CONFIG_CHANGED_EXTERNALLY "$HISTORY_FILE" || die missing_event
! grep -q $'\tROLLBACK\t' "$HISTORY_FILE" || die blind_rollback
''',
    'one_lock_daemon_ui_cli': r'''
acquire_operation || die first_lock
if acquire_operation; then die concurrent_lock; fi
release_operation
acquire_operation || die released
release_operation
''',
    'stale_lock_reaped': r'''
mkdir "$OP_LOCK"
echo 999999 > "$OP_LOCK/pid"; echo 200 > "$OP_LOCK/identity"; echo fixture-boot > "$OP_LOCK/boot"
acquire_operation || die stale_lock
release_operation
''',
    'autodetect_requires_activity_ambiguity_fails': r'''
backend_choice=auto
select_backend || die active_podkop
eq "$BACKEND" podkop
active_netshift=1
if select_backend; then die ambiguous; fi
active_podkop=0
select_backend || die netshift
eq "$BACKEND" forkozz
active_netshift=0
if select_backend; then die stale_config; fi
backend_choice=forkop
select_backend || die explicit_stopped
eq "$BACKEND" forkop
''',
    'forkop_schemas_and_multiple_children_guard': r'''
backend_choice=forkop
for legacy_field in section_interface interfaces interface; do
select_backend || die "$legacy_field"
eq "$INTERFACE_KEY" "forkop.main.$legacy_field"
done
child_count=1
select_backend || die child
eq "$INTERFACE_KEY" forkop.child1.name
child_count=2
if select_backend; then die multiple_interfaces; fi
''',
    'only_section_allowlist_nonstandard_names': r'''
eq "$(discover_interfaces | tr '\n' ' ')" 'DE_custom NL_2 SE_vpn '
if allowed_interface XBOX; then die foreign_section; fi
''',
    'manual_selection_resets_old_failures': r'''
main_bad=1
cycle
eq "$(cat "$FAIL_FILE")" 1
cfg_iface=SE_vpn
cycle || die manual
eq "$(cat "$FAIL_FILE")" 0
''',
    'monotonic_cooldown_ignores_wall_clock': r'''
runtime=0; cycle || die recover
eq "$(cat "$STATE_DIR/retry-at")" 1120
date() { echo 9999999999; }
cycle
eq "$(wc -l < "$STATE_DIR/starts" | tr -d ' ')" 1 wall_clock_storm
''',
}

def run_case(name, body, fixture_setup=setup):
    state = OUT / name
    state.mkdir(exist_ok=True)
    env = os.environ.copy()
    env['TEST_STATE'] = str(state).replace('\\', '/')
    script = OUT / (name + '.sh')
    # Redefine jq as a function so Windows fixtures use the same real jq program.
    content = f'jq() {{ "{jq}" "$@"; }}\n' + header + lib + fixture_setup + body + '\n'
    script.write_text(content, encoding='utf-8', newline='\n')
    proc = subprocess.run(argv + [str(script)], env=env, text=True, encoding='utf-8',
                          errors='replace', stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    (state / 'stdout.txt').write_text(proc.stdout or '', encoding='utf-8')
    (state / 'stderr.txt').write_text(proc.stderr or '', encoding='utf-8')
    assert proc.returncode == 0, f'{name}\n{proc.stdout}\n{proc.stderr}'
    print('PASS:', name)

def production(*names):
    """Restore just the real functions exercised by a lower-level test."""
    pieces = []
    for name in names:
        match = re.search(r'^' + name + r'\(\) \{', lib, re.M)
        assert match, name
        following = re.search(r'^\w+\(\) \{', lib[match.end():], re.M)
        end = match.end() + following.start() if following else len(lib)
        pieces.append(lib[match.start():end])
    return '\n'.join(pieces)

LOW_LEVEL = {
    'check_time_records_completed_probe_and_keeps_active_separate': production('probe_interface', 'record_check') + r'''
backend_choice=forkozz; select_backend || die select
CURRENT=DE_custom
probe_interface_impl() { PROBE_CODE=HEALTHY; return 0; }
probe_interface DE_custom || die probe
jq -e '.backend=="forkozz" and .interface=="DE_custom" and .result=="HEALTHY" and .code==0 and (.time|length)>10' "$STATE_DIR/last-active-check.json" >/dev/null || die active_metadata
original="$(cat "$STATE_DIR/last-active-check.json")"
probe_interface_impl() { PROBE_CODE=NO_HANDSHAKE; return 1; }
probe_interface NL_2; rc=$?
eq "$rc" 1 preserve_probe_rc
eq "$(cat "$STATE_DIR/last-active-check.json")" "$original" reserve_does_not_replace_active
jq -e '.interface=="NL_2" and .result=="NO_HANDSHAKE" and .code==1' "$STATE_DIR/last-check.json" >/dev/null || die failed_metadata
promote_active_check NL_2
eq "$(cat "$STATE_DIR/last-active-check.json")" "$original" do_not_promote_failure
PROBE_CODE=HEALTHY; record_check NL_2 0
original="$(cat "$STATE_DIR/last-check.json")"
promote_active_check NL_2
eq "$(jq -c . "$STATE_DIR/last-active-check.json")" "$(printf '%s' "$original" | jq -c .)" promote_without_new_time
''',
    'status_read_does_not_fabricate_time_and_rejects_stale_backend': production('show_dashboard', 'show_status', 'record_check') + r'''
backend_choice=forkozz; active_netshift=1; active_podkop=0; select_backend || die select
CURRENT=DE_custom; PROBE_CODE=HEALTHY
record_check DE_custom 0 || die record
original="$(cat "$STATE_DIR/last-active-check.json")"
podkop_runtime_ready() { return 0; }
show_dashboard > "$STATE_DIR/dash.json"
jq -e '.backend_label=="Forkozz (NetShift)" and .backend_active and .last_active_check.result=="HEALTHY" and .check_fresh' "$STATE_DIR/dash.json" >/dev/null || die initial_metadata
printf '%s\n' "$(config_fingerprint)" > "$STATE_DIR/confirmed-config"
echo RECOVERED > "$STATE_DIR/state"
show_dashboard > "$STATE_DIR/dash.json"
jq -e '.ready==true' "$STATE_DIR/dash.json" >/dev/null || die verified
PROBE_CODE=HTTPS_FAILURE; record_check DE_custom 1
show_dashboard > "$STATE_DIR/dash.json"
jq -e '.ready==false and .last_active_check.code==1' "$STATE_DIR/dash.json" >/dev/null || die false_green_after_manual_failure
PROBE_CODE=HEALTHY; record_check DE_custom 0
original="$(cat "$STATE_DIR/last-active-check.json")"
show_status > "$STATE_DIR/status.txt" || die status
awk '!/^\[Forkozz \(NetShift\)\] / {exit 1}' "$STATE_DIR/status.txt" || die wrong_status_name
T=2000
show_dashboard > "$STATE_DIR/dash.json"
jq -e '.check_fresh==false and .last_check_age_seconds==1000' "$STATE_DIR/dash.json" >/dev/null || die stale
eq "$(cat "$STATE_DIR/last-active-check.json")" "$original" read_only
backend_choice=podkop
show_dashboard > "$STATE_DIR/dash.json"
jq -e '.last_active_check==null and .check_fresh==false' "$STATE_DIR/dash.json" >/dev/null || die wrong_backend_check
''',
    'untrusted_manifest_directory_is_not_reaped': production('trusted_directory') + r'''
stat() { echo 1000:700; }
if trusted_directory "$STATE_DIR"; then die untrusted_owner; fi
stat() { echo 0:777; }
if trusted_directory "$STATE_DIR"; then die public_manifest; fi
stat() { echo 0:700; }
trusted_directory "$STATE_DIR" || die private_root_directory
''',
    'service_stop_cancels_explicit_recovery_without_more_writes': r'''
acquire_operation || die lock
EXPECTED_CONFIG="$(config_fingerprint)"
echo new-generation > "$STATE_DIR/cancel-generation"
adapter_set_interface NL_2; rc=$?
eq "$rc" 3
eq "$REASON" OPERATION_CANCELLED
eq "$cfg_iface" DE_custom
release_operation
''',
    'healthy_awg_broken_backend_path_repairs_same_interface': production('runtime_healthy') + r'''
runtime=1; path_bad=1
cycle
eq "$cfg_iface" DE_custom preserve_healthy_tunnel
[ -f "$STATE_DIR/starts" ] || die backend_not_repaired
[ ! -f "$FAIL_FILE" ] || eq "$(cat "$FAIL_FILE")" 0 not_awg_failure
''',
    'unavailable_path_verifier_never_reloads_healthy_engine': production('runtime_healthy') + r'''
verify_path() { REASON=PATH_TEST_UNAVAILABLE; return 2; }
cycle; rc=$?
eq "$rc" 2
eq "$(cat "$STATE_DIR/state")" VERIFYING
[ ! -f "$STATE_DIR/starts" ] || die unnecessary_reload
''',
    'bounded_history_redacts_urls_and_does_not_export_snapshots': r'''
acquire_operation || die lock
HISTORY_LIMIT=3
for n in 1 2 3 4 5; do operation TEST DE_custom NL_2 "message=$n https://example.invalid/feed?token=fixture-secret"; done
eq "$(wc -l < "$HISTORY_FILE" | tr -d ' ')" 3 bounded
! grep -q fixture-secret "$HISTORY_FILE" || die secret_url
grep -q 'URL REDACTED' "$HISTORY_FILE" || die redaction
release_operation
''',
    'main_failure_runtime_stopped_all_three_adapters': r'''
for backend_choice in podkop forkop forkozz; do
    active_podkop=0; active_forkop=0; active_netshift=0
    case "$backend_choice" in podkop) active_podkop=1;; forkop) active_forkop=1;; forkozz) active_netshift=1;; esac
    cfg_iface=DE_custom; runtime=0; main_bad=1; FAIL_THRESHOLD=1
    reset_counters
    cycle || die "$backend_choice recovery"
    eq "$cfg_iface" NL_2 "$backend_choice interface"
    eq "$(cat "$STATE_DIR/state")" RECOVERED "$backend_choice readiness"
done
''',
    'actual_engine_api_tests_selected_section_not_main_assumption': production('verify_path', 'verify_podkop_binding', 'outbound_tag') + r'''
acquire_operation || die lock
SING_BOX_CONFIG="$STATE_DIR/runtime.json"
echo '{"outbounds":[{"tag":"main-out","type":"direct","bind_interface":"DE_custom"},{"tag":"XBOX-out","type":"direct","bind_interface":"XBOX"}],"experimental":{"clash_api":{"external_controller":"0.0.0.0:9090","secret":"fixture"}}}' > "$SING_BOX_CONFIG"
nft() { echo 'tproxy to :1602'; }
ip() { case "$*" in *'route show'*) echo 'local default dev lo';; *) echo '100: from all fwmark 0x10000 lookup podkop';; esac; }
probe_curl() {
    echo "$*" >> "$STATE_DIR/api-requests"
    case "$*" in *vpn-failover.invalid*) return 22;; *) echo '{"delay":42}';; esac
}
verify_path DE_custom || die api_path
grep -q '127.0.0.1:9090/proxies/main-out/delay' "$STATE_DIR/api-requests" || die wrong_tag
! grep -q 'proxies/XBOX-out' "$STATE_DIR/api-requests" || die other_section_path
probe_curl() { echo '{"delay":42}'; }
verify_path DE_custom; rc=$?
eq "$rc" 2 synthetic_api_rejected
eq "$REASON" PATH_TEST_INVALID
release_operation
''',
    'route_collision_and_crash_cleanup_never_flush_foreign': production('prepare_routes', 'cleanup_routes') + r'''
acquire_operation || die lock
ip() {
    echo "$*" >> "$STATE_DIR/ip-commands"
    case "$*" in
        '-4 rule show') echo '0: from all lookup local'; [ ! -f "$STATE_DIR/own-rule" ] || cat "$STATE_DIR/own-rule";;
        '-4 route show table 42800') echo 'default dev FOREIGN proto static';;
        '-4 route show table 42801') [ ! -f "$STATE_DIR/own-route" ] || cat "$STATE_DIR/own-route";;
        '-4 route add table 42801 default dev NL-dev proto 186') echo 'default dev NL-dev proto 186 scope link' > "$STATE_DIR/own-route";;
        '-4 rule add pref 2 oif NL-dev lookup 42801 protocol 186') echo '2: from all oif NL-dev lookup 42801 proto 186' > "$STATE_DIR/own-rule";;
        '-4 route del table 42801 default dev NL-dev proto 186') rm -f "$STATE_DIR/own-route";;
        '-4 rule del pref 2 oif NL-dev lookup 42801 protocol 186') rm -f "$STATE_DIR/own-rule";;
    esac
    return 0
}
prepare_routes NL-dev || die private_route
eq "$ROUTE_TABLE" 42801 skip_foreign
eq "$(cat "$OP_LOCK/route")" '42801 2 NL-dev'
cleanup_routes "$OP_LOCK" || die cleanup
[ ! -f "$STATE_DIR/own-rule" ] && [ ! -f "$STATE_DIR/own-route" ] || die leak
! grep -Eq 'flush|del.*42800|del.*FOREIGN' "$STATE_DIR/ip-commands" || die foreign_mutation
release_operation
''',
    'bounded_deadline_and_process_group_cleanup': production('bounded') + r'''
acquire_operation || die lock
echo 1000 > "$STATE_DIR/clock"
monotonic() { cat "$STATE_DIR/clock"; }
sleep() { n="$(cat "$STATE_DIR/clock")"; echo "$((n+1))" > "$STATE_DIR/clock"; }
setsid() { :; }
kill() { return 0; }
kill_child() { [ -z "$CHILD" ] || wait "$CHILD"; CHILD=''; echo cancelled > "$STATE_DIR/cancelled"; }
DEADLINE=1003
bounded 60 ignored; rc=$?
eq "$rc" 124
eq "$(cat "$STATE_DIR/clock")" 1003 whole_deadline
eq "$(cat "$STATE_DIR/cancelled")" cancelled
release_operation
''',
    'new_fatal_rejects_stable_pid_and_old_fatal_ignored': production('runtime_log_cursor', 'runtime_no_fatal') + r'''
acquire_operation || die lock
printf '%s\n' 'old daemon.err sing-box[1]: FATAL old failure' 'old marker' > "$STATE_DIR/system-log"
logread() { cat "$STATE_DIR/system-log"; }
runtime_log_cursor || die cursor
runtime_no_fatal || die old_fatal
echo 'new daemon.err sing-box[2]: FATAL downloading rule-set' >> "$STATE_DIR/system-log"
if runtime_no_fatal; then die fresh_fatal_ignored; fi
release_operation
''',
    'dns_bootstrap_reserve_seeds_cache_before_counting_failure': r'''
main_unknown=1; FAIL_THRESHOLD=1
probe_interface() {
    echo "$1" >> "$STATE_DIR/probes"
    case "$1" in
        DE_custom)
            if [ ! -f "$STATE_DIR/dns-ready" ]; then PROBE_CODE=DNS_FAILURE; return 2; fi
            PROBE_CODE=HTTPS_FAILURE; return 1;;
        *) echo ready > "$STATE_DIR/dns-ready"; PROBE_CODE=HEALTHY; ENDPOINT=endpoint; return 0;;
    esac
}
cycle || die recovery
eq "$cfg_iface" NL_2
eq "$(cat "$STATE_DIR/state")" RECOVERED
''',
    'other_live_backend_blocks_any_start': r'''
runtime=0; active_netshift=1
cycle; rc=$?
eq "$rc" 2
eq "$(cat "$STATE_DIR/reason")" OTHER_BACKEND_ACTIVE
[ ! -f "$STATE_DIR/starts" ] || die conflict_start
''',
    'binding_selected_section_singleton_selector': production('verify_podkop_binding', 'outbound_tag') + r'''
SING_BOX_CONFIG="$STATE_DIR/runtime.json"
printf '%s' '{"outbounds":[{"tag":"main-out","type":"direct","bind_interface":"DE_custom"},{"tag":"XBOX-out","type":"direct","bind_interface":"XBOX"}]}' > "$SING_BOX_CONFIG"
verify_podkop_binding DE_custom || die binding
if verify_podkop_binding XBOX; then die wrong_section; fi
BACKEND=forkop
printf '%s' '{"outbounds":[{"tag":"main","type":"selector","outbounds":["main/NL"]},{"tag":"main/NL","type":"direct","bind_interface":"NL_2"}]}' > "$SING_BOX_CONFIG"
verify_podkop_binding NL_2 || die forkop_selector
printf '%s' '{"outbounds":[{"tag":"main","type":"selector","outbounds":["main/NL","direct"]},{"tag":"main/NL","type":"direct","bind_interface":"NL_2"}]}' > "$SING_BOX_CONFIG"
if verify_podkop_binding NL_2; then die ambiguous_selector; fi
''',
    'native_backend_starts_engine_once_oneshot_normal': production('ensure_started') + r'''
runtime=0; START_ATTEMPTS=0; OWNED_TO=DE_custom
acquire_operation || die lock
runtime_log_cursor() { :; }; runtime_no_fatal() { :; }
adapter_apply() { echo backend >> "$STATE_DIR/native"; runtime=1; }
verify_podkop_binding() { :; }
bounded() { echo "$*" >> "$STATE_DIR/native"; return 0; }
runtime_pid() { echo "$$"; }
ensure_started || die ensure
eq "$(grep -c backend "$STATE_DIR/native")" 1 backend_once
! grep -q '/etc/init.d/sing-box start' "$STATE_DIR/native" || die duplicate_engine_start
eq "$START_ATTEMPTS" 1
release_operation
''',
    'exhausted_respawn_gets_real_start_not_enable': production('ensure_started') + r'''
runtime=0; START_ATTEMPTS=0; OWNED_TO=DE_custom
acquire_operation || die lock
runtime_log_cursor() { :; }; runtime_no_fatal() { :; }
adapter_apply() { :; }
verify_podkop_binding() { :; }
bounded() { echo "$*" >> "$STATE_DIR/native"; case "$*" in *'/etc/init.d/sing-box start') runtime=1;; esac; }
runtime_pid() { [ "$runtime" = 1 ] && echo "$$"; }
ensure_started || die ensure
grep -q '/etc/init.d/sing-box start' "$STATE_DIR/native" || die real_start_missing
! grep -Eq 'enable|disable|restart' "$STATE_DIR/native" || die changed_autostart
eq "$START_ATTEMPTS" 2
if ensure_started; then die excessive_attempts; fi
release_operation
''',
    'stale_generated_binding_never_started': production('ensure_started') + r'''
runtime=0; START_ATTEMPTS=0; OWNED_TO=NL_2
acquire_operation || die lock
runtime_log_cursor() { :; }; runtime_no_fatal() { :; }
adapter_apply() { :; }
verify_podkop_binding() { return 1; }
bounded() { echo "$*" >> "$STATE_DIR/native"; }
if ensure_started; then die stale_start; fi
eq "$REASON" CONFIG_BINDING_INVALID
[ ! -f "$STATE_DIR/native" ] || die engine_started_old_config
release_operation
''',
    'native_adapter_commands_are_backend_specific': production('adapter_apply') + r'''
bounded() { shift; echo "$*" >> "$STATE_DIR/native"; }
for BACKEND in podkop forkop forkozz; do
    runtime=1; adapter_apply || die reload
    runtime=0; adapter_apply || die start
done
eq "$(cat "$STATE_DIR/native")" "$(printf '%s\n' '/etc/init.d/podkop reload' '/etc/init.d/podkop start' '/etc/init.d/forkop reload' '/etc/init.d/forkop start' '/usr/bin/netshift reload' '/etc/init.d/netshift start')" native_lifecycle
''',
    'two_https_targets_one_failure_is_not_awg_down': production('https_targets') + r'''
acquire_operation || die lock
CURRENT_PROBE=DE_custom
resolve_target() { echo 203.0.113.7; }
awg_rx() { n="$(counter "$STATE_DIR/rx")"; echo "$((n+1))" > "$STATE_DIR/rx"; echo "$n"; }
awg_handshake() { [ "${handshake:-1}" = 1 ]; }
probe_curl() {
    echo "$*" >> "$STATE_DIR/requests"
    case "$*" in
        *www.cloudflare.com*) return 28;;
        *www.msftconnecttest.com*) printf 'Microsoft Connect Test' > "$OP_LOCK/probe-body"; printf 200;;
    esac
}
https_targets DE_custom || die single_provider_outage
eq "$PROBE_CODE" HEALTHY
eq "$(wc -l < "$STATE_DIR/requests" | tr -d ' ')" 2 targets
handshake=0
if https_targets DE_custom; then die no_handshake; fi
eq "$PROBE_CODE" NO_HANDSHAKE
release_operation
''',
    'captive_content_and_dns_infrastructure_are_distinct': production('https_targets') + r'''
acquire_operation || die lock
CURRENT_PROBE=DE_custom
resolve_target() { echo 203.0.113.7; }
awg_rx() { echo 100; }; awg_handshake() { :; }
probe_curl() { echo '<html>Login to Wi-Fi</html>' > "$OP_LOCK/probe-body"; printf 200; }
if https_targets DE_custom; then die captive_accepted; fi
eq "$PROBE_CODE" HTTPS_FAILURE
resolve_target() { return 2; }
https_targets DE_custom; rc=$?
eq "$rc" 2 dns_not_awg_failure
eq "$PROBE_CODE" DNS_FAILURE
release_operation
''',
    'actual_path_missing_verification_fails_closed': production('verify_path') + r'''
acquire_operation || die lock
SING_BOX_CONFIG="$STATE_DIR/runtime.json"
echo '{"outbounds":[{"tag":"main-out","type":"direct","bind_interface":"DE_custom"}]}' > "$SING_BOX_CONFIG"
verify_podkop_binding() { :; }
nft() { echo 'tproxy to :1602'; }
ip() { case "$*" in *'route show'*) echo 'local default dev lo';; *) echo '100: from all fwmark 0x10000 lookup podkop';; esac; }
verify_path DE_custom; rc=$?
eq "$rc" 2
eq "$REASON" PATH_TEST_UNAVAILABLE
release_operation
''',
    'readonly_dashboard_and_status_never_mutate_or_probe': production('show_dashboard', 'show_status') + r'''
SING_BOX_CONFIG="$STATE_DIR/runtime.json"
podkop_runtime_ready() { return 0; }
probe_interface() { die read_only_probe; }
ensure_state_dir() { die read_only_mkdir; }
state() { die read_only_state_write; }
cycle() { die read_only_recovery; }
show_dashboard > "$STATE_DIR/dashboard.json" || die dashboard
jq -e '.runtime == true and .ready == false and .current == "DE_custom"' "$STATE_DIR/dashboard.json" >/dev/null || die json
show_status >/dev/null || die status
''',
    'deadline_exhausted_no_configuration_write': r'''
acquire_operation || die lock
DEADLINE=999
adapter_set_interface NL_2; rc=$?
eq "$rc" 3
eq "$cfg_iface" DE_custom
release_operation
''',
}

if __name__ == '__main__':
    for name, body in CASES.items():
        run_case(name, body)
    for name, body in LOW_LEVEL.items():
        run_case(name, body)

