"""Exercise the installer's actual service-state restoration branch locally."""
import os
from pathlib import Path
import subprocess
import shutil
ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'install.sh').read_text(encoding='utf-8')
# The final printing branch is later than the restoration branch.
start = source.index('if [ "$existing_install" -eq 1 ]; then\n    if [ "$was_enabled"')
branch = source[start:source.index('\nrm -f "$TMP_WORKER"', start)]
out = ROOT / 'test-output' / ('install-' + str(os.getpid()))
out.mkdir(parents=True, exist_ok=True)
busybox = os.environ.get('TEST_BUSYBOX')
argv = [busybox, 'sh'] if busybox else [os.environ.get('TEST_SHELL') or shutil.which('sh')]
for existing in (0, 1):
    for running in (0, 1):
        for enabled in (0, 1):
            record = out / f'{existing}-{running}-{enabled}.txt'
            script = out / f'{existing}-{running}-{enabled}.sh'
            script.write_text(f'''existing_install={existing}
was_running={running}
was_enabled={enabled}
INIT_DST=init_fixture
CONTROL_DST=control_fixture
RECORD="$TEST_RECORD"
init_fixture() {{ echo "init $*" >> "$RECORD"; }}
control_fixture() {{ echo "control $*" >> "$RECORD"; }}
info() {{ :; }}
fail() {{ echo "$*" >&2; exit 1; }}
''' + branch, encoding='utf-8', newline='\n')
            env = os.environ.copy()
            env['TEST_RECORD'] = str(record).replace('\\', '/')
            p = subprocess.run(argv + [str(script)], env=env, capture_output=True, timeout=10)
            assert p.returncode == 0, p.stderr
            calls = record.read_text().splitlines()
            assert ('control restart' in calls) == bool(existing and running), calls
            assert ('init enable' in calls) == bool(existing and enabled), calls
            assert not any(x.startswith(('backend', 'sing-box')) for x in calls)
print('PASS: installer preserves all running/enabled combinations; fresh install stays stopped')
assert '"${BASE_URL}/recovery.sh"' in source
assert 'Cannot save migrated settings' in source
assert 'uci -q changes vpn_failover' in source
assert 'value="$(tr -d' in source
print('PASS: recovery library installation and non-evaluating numeric settings migration guards')
