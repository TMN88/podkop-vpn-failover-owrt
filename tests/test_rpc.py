"""Validate the real RPC schema and rejection of arbitrary command input."""
from pathlib import Path
import os,shutil,subprocess,json
root=Path(__file__).resolve().parents[1]
busybox=os.environ.get('TEST_BUSYBOX')
shell=os.environ.get('TEST_SHELL') or shutil.which('sh')
source=(root/'vpn-failover.rpc').read_text(encoding='utf-8')
if os.environ.get('TEST_JQ'):
    source=source.replace('jq ', '"'+os.environ['TEST_JQ'].replace('\\','/')+'" ')
out=root/'test-output'/('rpc-'+str(os.getpid()));out.mkdir(parents=True,exist_ok=True)
os.environ['TEST_RPC_DIR']=str(out/'state').replace('\\','/')
source=source.replace('DIR=/tmp/podkop-vpn-failover-ui','DIR="$TEST_RPC_DIR"')
fixture=out/'rpc.sh';fixture.write_text(source,encoding='utf-8',newline='\n')
argv=[busybox,'sh'] if busybox else [shell]
def run(args,payload=None):
    return subprocess.run(argv+[str(fixture)]+args,input=json.dumps(payload) if payload is not None else '',text=True,encoding='utf-8',stdout=subprocess.PIPE,stderr=subprocess.PIPE)
r=run(['list']);assert r.returncode==0,r.stderr
assert set(json.loads(r.stdout))=={'status','job','diagnostics','run'}
for action in ['stop;touch /tmp/injected','$(id)','../config','test\nstart','__job','']:
    r=run(['call','run'],{'action':action});assert r.returncode==0,(action,r.stderr)
    assert json.loads(r.stdout)['accepted'] is False,action
for payload in [{},{'action':[]},{'action':None}]:
    assert run(['call','run'],payload).returncode!=0,payload
assert run(['call','arbitrary']).returncode!=0
acl=json.loads((root/'luci-acl.json').read_text(encoding='utf-8'))['vpn-failover']
assert 'run' not in acl['read']['ubus']['vpn-failover']
assert acl['write']['ubus']['vpn-failover']==['run']
print('PASS: RPC schema, input whitelist, invalid payloads and separate management permission')
state=out/'state';state.mkdir(exist_ok=True)
for name,value in {'action':'test','backend':'forkozz','section':'main','code':'0','output':'native output'}.items():
    (state/name).write_text(value,encoding='utf-8')
r=run(['call','job']);assert r.returncode==0,r.stderr
job=json.loads(r.stdout)
assert job['backend']=='forkozz' and job['section']=='main' and job['output']=='native output'
assert job['running'] is False
print('PASS: completed job retains its own bypass context without reading/changing backend')
