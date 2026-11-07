const fs=require('fs'),assert=require('assert'),path=require('path');
const source=fs.readFileSync(path.join(__dirname,'..','vpn-failover.js'),'utf8');
let tick,downloaded=false,blob;
function E(tag,attrs={},children=[]){return {tag,attrs,children,textContent:'',disabled:false,
    appendChild(c){this.children.push(c);},replaceChild(c,old){this.children[this.children.indexOf(old)]=c;},
    click(){if(tag==='a')downloaded=true;else return attrs.click();},remove(){},
    getAttribute(k){return this.attrs[k];},querySelectorAll(){return all(this,'details').filter(n=>n.open||n.attrs.open==='');}};}
let data={version:'0.2.1',running:true,enabled:true,runtime:true,backend:'forkozz',section:'main',current:'awg1',error:'',events:[
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
    const buttons=all(page,'button');assert.equal(buttons.length,7);
    assert.deepEqual(buttons.slice(0,6).map(b=>b.children),['Запустить','Остановить','Перезапустить','Статус','Проверить туннели','Настройки']);
    const history=all(page,'details').find(d=>d.attrs.class==='pvf-history');assert(!history.open);
    history.open=true;await tick();assert.equal(history.open,true);
    const technical=all(page,'details').find(d=>d.attrs['data-event-key']);technical.open=true;
    await tick();assert(all(page,'details').some(d=>d.attrs['data-event-key']&&d.attrs.open===''));
    assert(all(page,'div').some(n=>typeof n.children==='string'&&n.children.includes('Привязка и доступ')));
    assert(all(page,'pre').some(n=>n.children==='<img src=x onerror=alert(1)>'));
    assert.equal(all(page,'img').length,0);
    job={running:true,action:'start',code:null,output:''};await buttons[0].click();assert.equal(calls[0],'start');assert(buttons[0].disabled);
    job={running:false,action:'start',code:0,output:'started'};await tick();assert(!buttons[0].disabled);
    assert(all(page,'pre').some(n=>n.textContent.includes('started')));
    runError=true;await buttons[4].click();assert(!buttons[4].disabled);assert(all(page,'pre').some(n=>n.textContent.includes('Busy')));
    await buttons[6].click();assert(downloaded);const diag=JSON.parse(blob.text);assert.equal(diag.format,'vpn-failover-diagnostics-v1');assert.equal(diag.last_command.code,0);
    data={...data,events:[]};await tick();assert(all(page,'td').some(n=>n.children==='Операций пока нет.'));
    readError=true;await tick();assert(all(page,'p').some(n=>n.textContent.includes('Не удалось обновить')));
    console.log('PASS: unified controls, async job, errors, collapsible history, safe text, diagnostics download');
})().catch(e=>{console.error(e);process.exitCode=1;});
