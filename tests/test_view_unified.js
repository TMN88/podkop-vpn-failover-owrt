const fs=require('fs'),assert=require('assert'),path=require('path');
const source=fs.readFileSync(path.join(__dirname,'..','vpn-failover.js'),'utf8');
let tick,downloaded=false,blob;
function E(tag,attrs={},children=[]){return {tag,attrs,children,textContent:'',disabled:false,
    appendChild(c){this.children.push(c);},replaceChild(c,old){this.children[this.children.indexOf(old)]=c;},
    click(){if(tag==='a')downloaded=true;else return attrs.click();},remove(){},
    getAttribute(k){return this.attrs[k];},querySelectorAll(){return all(this,'details').filter(n=>n.open||n.attrs.open==='');}};}
let data={version:'0.3.0-dev',running:true,enabled:true,runtime:true,backend:'forkozz',backend_installed:true,backend_active:true,ready:true,check_fresh:true,
    last_active_check:{time:'2026-11-19T12:00:00+03:00',interface:'awg1',result:'HEALTHY',code:0},section:'main',current:'awg1',error:'',events:[
    {time:'2026-11-07',event:'success',from:'awg0',to:'awg1',detail:'<img src=x onerror=alert(1)>',backend:'forkozz',section:'main'}]};
let job={running:false,action:'',code:null,output:''},runError=false,readError=false,calls=[];
const rpc={declare(spec){return function(action){
    if(spec.method==='status')return readError?Promise.reject(new Error('network')):Promise.resolve(data);
    if(spec.method==='job')return Promise.resolve(job);
    if(spec.method==='diagnostics')return Promise.resolve({format:'vpn-failover-diagnostics-v1',snapshot:data,settings:'CHECK_INTERVAL=30'});
    calls.push(action);return runError?Promise.resolve({accepted:false,error:'Busy'}):Promise.resolve({accepted:true});
};}};
const fakeURL={createObjectURL(b){blob=b;return 'blob:test';},revokeObjectURL(){}};
class FakeBlob{constructor(parts){this.text=parts.join('');}}
const document={body:E('body',{},[])};
const view=new Function('view','rpc','poll','E','URL','Blob','document','setTimeout',source)(
    {extend:x=>x},rpc,{add(f,n){tick=f;assert.equal(n,5);}},E,fakeURL,FakeBlob,document,f=>f());
function all(node,tag){if(!node||typeof node!=='object')return [];return (node.tag===tag?[node]:[]).concat((Array.isArray(node.children)?node.children:[]).flatMap(c=>all(c,tag)));}
(async()=>{
    const page=view.render(await view.load());
    const buttons=all(page,'button');assert.equal(buttons.length,5);
    assert.deepEqual(buttons.map(b=>b.children),['Проверить туннели','Запустить','Остановить','Перезапустить','Скачать логи для диагностики']);
    data={...data,tunnel_checks:[{interface:'awg1',result:'HEALTHY',code:0},{interface:'awg2',result:'HTTPS_FAILURE',code:1},{interface:'awg3'}]};
    await tick();
    for(const [i, status] of [['awg1','активный: отвечал'],['awg2','HTTPS через туннель не подтвердился'],['awg3','ещё не проверялся']])
        assert(all(page,'span').some(n=>n.children.startsWith(i+' · ')&&n.children.includes(status)));
    const history=all(page,'details').find(d=>d.attrs.class==='pvf-history');assert(!history.open);
    history.open=true;await tick();assert.equal(history.open,true);
    const technical=all(page,'details').find(d=>d.attrs['data-event-key']);technical.open=true;
    await tick();assert(all(page,'details').some(d=>d.attrs['data-event-key']&&d.attrs.open===''));
    assert(all(page,'div').some(n=>typeof n.children==='string'&&n.children.includes('Привязка и доступ')));
    assert(all(page,'pre').some(n=>n.children==='[Forkozz (NetShift)] <img src=x onerror=alert(1)>'));
    assert.equal(all(page,'img').length,0);
    const named=cls=>all(page,'strong').concat(all(page,'p')).find(n=>n.attrs.class===cls);
    assert.equal(named('pvf-backend-name').textContent,'Forkozz (NetShift)');
    assert(named('pvf-backend-status').textContent.includes('Работает — маршрут подтверждён'));
    const originalCheck=named('pvf-last-check').textContent;
    await tick();assert.equal(named('pvf-last-check').textContent,originalCheck,'page refresh must not fabricate a check time');
    assert(all(page,'td').some(n=>n.children==='Forkozz (NetShift)'));
    job={running:true,action:'start',code:null,output:''};await buttons[1].click();assert.equal(calls[0],'start');assert(buttons[1].disabled);
    job={running:false,action:'start',backend:'forkozz',code:0,output:'started\nsecond line'};await tick();assert(!buttons[1].disabled);
    assert(all(page,'pre').some(n=>n.textContent.includes('started')));
    assert(all(page,'pre').some(n=>n.textContent.includes('[Forkozz (NetShift)] second line')));
    for(const [backend,title] of [['podkop','Podkop'],['forkop','Forkop'],['forkozz','Forkozz (NetShift)']]){
        data={...data,backend};await tick();assert.equal(named('pvf-backend-name').textContent,title);
    }
    data={...data,check_fresh:false};await tick();assert(named('pvf-backend-status').textContent.includes('устарела'));
    data={...data,last_active_check:null,ready:false,check_fresh:false};await tick();assert(named('pvf-last-check').textContent.includes('ещё не выполнялась'));
    data={...data,runtime:false};await tick();assert(named('pvf-backend-status').textContent.includes('Не работает'));
    data={...data,backend:'',error:'BACKEND_AMBIGUOUS'};await tick();assert.equal(named('pvf-backend-name').textContent,'Обход не определён');
    assert(all(page,'td').some(n=>n.children==='Forkozz (NetShift)'),'historical event retains its real backend');
    assert(all(page,'pre').some(n=>n.textContent.includes('[Forkozz (NetShift)] started')),'job retains its original backend after selection changes');
    data={...data,backend:'forkozz',error:''};await tick();
    runError=true;await buttons[0].click();assert(!buttons[0].disabled);assert(all(page,'pre').some(n=>n.textContent.includes('Busy')));
    await buttons[4].click();assert(downloaded);const diag=JSON.parse(blob.text);assert.equal(diag.format,'vpn-failover-diagnostics-v1');assert.equal(diag.last_command.code,0);
    data={...data,events:[]};await tick();assert(all(page,'td').some(n=>n.children==='Операций пока нет.'));
    readError=true;await tick();assert(all(page,'p').some(n=>n.textContent.includes('Не удалось обновить')));
    console.log('PASS: unified controls, async job, errors, collapsible history, safe text, diagnostics download');
})().catch(e=>{console.error(e);process.exitCode=1;});
