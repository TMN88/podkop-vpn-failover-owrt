"""Portable local validation. TEST_BUSYBOX/TEST_JQ are optional fixture tools."""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
ROOT = Path(__file__).resolve().parents[1]
out = ROOT / 'test-output' / ('validation-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
out.mkdir(parents=True, exist_ok=True)
bb = os.environ.get('TEST_BUSYBOX')
shell = [bb, 'sh'] if bb else [os.environ.get('TEST_SHELL') or shutil.which('sh')]
scripts = ['podkop-vpn-failover', 'recovery.sh', 'podkop-vpn-failover-control',
           'podkop-vpn-failover.init', 'vpn-failover.rpc', 'install.sh', 'uninstall.sh']
commands = [('syntax-' + name, shell + ['-n', name]) for name in scripts]
commands += [(name, [sys.executable, 'tests/' + name + '.py']) for name in
             ['test_backend', 'test_rpc', 'test_install', 'test_entrypoints']]
commands += [('test_view', ['node', 'tests/test_view.js']), ('diff-check', ['git', 'diff', '--check'])]
if '--baseline' in sys.argv:
    commands += [('baseline', [sys.executable, 'tests/test_baseline.py'])]
results = []
for name, command in commands:
    started = time.monotonic()
    p = subprocess.run(command, cwd=ROOT, capture_output=True, timeout=180)
    output = p.stdout.decode('utf-8', errors='replace')
    error = p.stderr.decode('utf-8', errors='replace')
    (out / (name + '.stdout.txt')).write_text(output, encoding='utf-8')
    (out / (name + '.stderr.txt')).write_text(error, encoding='utf-8')
    results.append({'name': name, 'returncode': p.returncode,
                    'duration_seconds': round(time.monotonic() - started, 3),
                    'pass_lines': output.count('PASS:')})
    print(('PASS' if p.returncode == 0 else 'FAIL') + ': ' + name, flush=True)
report = {'scope': 'local mocked validation only; no routers/deployment',
          'version': '0.3.0-dev.3', 'results': results}
(out / 'results.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(str(out), flush=True)
raise SystemExit(any(r['returncode'] != 0 for r in results))
