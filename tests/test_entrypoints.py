import time
"""Smoke-test the actual CLI dispatch with no services or network available."""
import json
import os
from pathlib import Path
import shutil
import subprocess
ROOT = Path(__file__).resolve().parents[1]
out = ROOT / 'test-output' / ('entrypoints-' + str(os.getpid()) + '-' + str(time.time_ns()))
out.mkdir(parents=True, exist_ok=True)
source = (ROOT / 'podkop-vpn-failover').read_text(encoding='utf-8')
jq = os.environ.get('TEST_JQ') or shutil.which('jq')
if not jq:
    raise SystemExit('Install jq or set TEST_JQ to its executable path')
jq = jq.replace('\\', '/')
fixture = out / 'worker.sh'
fixture.write_text(f'''uci() {{ return 1; }}
nft() {{ return 1; }}
ubus() {{ return 1; }}
curl() {{ echo forbidden_network_probe >&2; exit 90; }}
jq() {{ "{jq}" "$@"; }}
''' + source, encoding='utf-8', newline='\n')
env = os.environ.copy()
env['PVF_RECOVERY_LIB'] = str(ROOT / 'recovery.sh').replace('\\', '/')
bb = os.environ.get('TEST_BUSYBOX')
argv = [bb, 'sh'] if bb else [os.environ.get('TEST_SHELL') or shutil.which('sh')]
for command in ('version', 'config', 'status', 'dashboard'):
    p = subprocess.run(argv + [str(fixture), command], env=env, capture_output=True, timeout=15)
    assert p.returncode == 0, (command, p.stderr)
    assert b'forbidden_network_probe' not in p.stderr
    if command == 'version':
        assert p.stdout.strip() == b'0.3.0-dev.5', p.stdout
    if command == 'status':
        prefix='[Обход не определён]'.encode('utf-8')
        if os.name=='nt' and bb:
            # BusyBox-w32 passes UTF-8 argv to native jq through the Windows
            # ANSI code page. Real Linux/OpenWrt keeps the original UTF-8.
            prefix=prefix.decode('cp1251').encode('utf-8')
        assert p.stdout and all(line.startswith(prefix) for line in p.stdout.splitlines()), p.stdout
    if command == 'dashboard':
        d = json.loads(p.stdout)
        assert d['error'] == 'BACKEND_AMBIGUOUS' and d['ready'] is False
print('PASS: actual CLI version/config/status/dashboard dispatch; no live probes or starts')
