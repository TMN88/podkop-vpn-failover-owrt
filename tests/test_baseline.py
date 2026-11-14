"""Optional offline reproduction against the already fetched 0.2.1 git object.

Not required by shallow CI checkout. It must show the old bug, not pass the
new recovery acceptance. No remote access and no mutation of the working tree.
"""
import os
from pathlib import Path
import shutil
import subprocess
ROOT = Path(__file__).resolve().parents[1]
BASE = 'a6b5e553b2a4382e3782dd56dbf4cdbf1401bfa1'
p = subprocess.run(['git', 'show', BASE + ':podkop-vpn-failover'], cwd=ROOT,
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
source = p.stdout.decode('utf-8').split('\nselect_backend || :\n\ncase ')[0]
out = ROOT / 'test-output' / ('baseline-' + str(os.getpid()))
out.mkdir(parents=True, exist_ok=True)
script = out / 'baseline.sh'
script.write_text(source + r'''
probes=0; BACKEND_ERROR=''; STARTUP_GRACE_PERIOD=0
jq() { :; }
acquire_daemon_lock() { :; }
reset_failure_counter() { :; }
clear_no_reserve_cooldown() { :; }
now_epoch() { echo 1000; }
log_msg() { :; }
podkop_runtime_ready() { return 1; }
probe_interface() { probes=$((probes+1)); return 1; }
sleep() { echo "AWG_PROBES=$probes"; [ "$probes" -gt 0 ] || exit 42; exit 0; }
run_daemon
''', encoding='utf-8', newline='\n')
bb = os.environ.get('TEST_BUSYBOX')
argv = [bb, 'sh'] if bb else [os.environ.get('TEST_SHELL') or shutil.which('sh')]
p = subprocess.run(argv + [str(script)], capture_output=True, timeout=10)
assert p.returncode == 42 and b'AWG_PROBES=0' in p.stdout, (p.returncode, p.stdout, p.stderr)
(out / 'result.txt').write_text(f'{BASE}\nExpected old regression: exit=42\nAWG_PROBES=0\n', encoding='utf-8')
print('PASS: reproduced 0.2.1 regression offline: stopped runtime causes zero AWG probes')
