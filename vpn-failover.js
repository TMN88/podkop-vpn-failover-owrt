"use strict";
'require view';
'require rpc';
'require poll';

var statusRPC = rpc.declare({object:'vpn-failover',method:'status',expect:{}});
var jobRPC = rpc.declare({object:'vpn-failover',method:'job',expect:{}});
var runRPC = rpc.declare({object:'vpn-failover',method:'run',params:['action'],expect:{}});
var diagnosticsRPC = rpc.declare({object:'vpn-failover',method:'diagnostics',expect:{}});
var labels = {success:'Успешно',rollback:'Откат выполнен',rollback_failed:'Ошибка отката',notice:'Информация',warning:'Предупреждение',err:'Ошибка'};

function explain(e) {
    var s=e.detail || '', m;
    if(e.event==='success') return 'Переключились на '+e.to+'. Привязка и доступ в интернет проверены.';
    if(e.event==='rollback') return 'Вернулись на '+e.to+': резерв не прошёл проверку.';
    if(e.event==='rollback_failed') return 'Не удалось подтвердить возврат на '+e.to+'. Нужна диагностика.';
    if(s.indexOf('Switching ')===0) return 'Начинаем переход с '+e.from+' на '+e.to+'.';
    if(s.indexOf('Failover completed successfully')===0) return 'Переход завершён: '+e.to+'.';
    if((m=s.match(/^Health-check failed for ([^:]+): (\d+)\/(\d+)/))) return 'Туннель '+m[1]+' не отвечает. Неудачных проверок: '+m[2]+' из '+m[3]+'.';
    if(s.indexOf('Confirmed unhealthy')===0 || s.indexOf('Confirmed unavailable')===0) return 'Отказ текущего туннеля подтверждён. Начинаем поиск рабочего резерва.';
    if(s.indexOf('No-reserve retry interval expired')===0) return 'Повторно проверяем резервные туннели после паузы.';
    if((m=s.match(/^Testing failover candidate (.+)$/))) return 'Проверяем резервный туннель '+m[1]+'.';
    if(s.indexOf('Candidate ')===0 && s.indexOf('passed')>=0) return 'Резервный туннель прошёл проверку.';
    if(s.indexOf('Candidate ')===0 && s.indexOf('unhealthy')>=0) return 'Резервный туннель не прошёл проверку; проверим следующий.';
    if(s.indexOf('Post-switch health-check failed')===0) return 'После перехода интернет не подтвердился. Возвращаем прежний туннель.';
    if(s.indexOf('Startup grace period active')===0) return 'Первые 120 секунд после запуска: ждём готовности VPN.';
    if(s.indexOf('Startup grace period ended')===0) return 'Ожидание завершено. Мониторинг VPN включён.';
    if(s.indexOf('Started v')===0) return 'Служба запущена. Проверки выполняются каждые 30 секунд.';
    if(s.indexOf('runtime is not ready')>=0) return 'VPN-движок остановлен или его конфигурация не готова. Ожидаем запуска.';
    if(s.indexOf('connection type is')>=0) return 'Секция сейчас работает без AWG (например, через прокси). Переключение туннелей не выполняется.';
    if(s.indexOf('No healthy')===0) return 'Рабочих резервных туннелей пока нет. Повторим проверку позже.';
    if(s.indexOf('recovered')>=0) return 'Связь через текущий туннель восстановилась.';
    if(s.indexOf('externally')>=0 || s.indexOf('outside failover')>=0) return 'Выбор туннеля изменён вне службы. Сохраняем новый выбор.';
    return 'Техническое сообщение. Подробности доступны ниже и в скачиваемом логе.';
}
function eventRows(data,expanded) {
    expanded=expanded||new Set();
    return (data.events || []).map(function(e) {
        var key=e.time+'|'+e.event+'|'+e.detail;
        var color=e.event==='success'?'#23783d':(e.event==='err'||e.event==='rollback_failed'?'#a32626':'#705300');
        return E('tr',{'class':'tr'},[
            E('td',{'class':'td'},e.time),
            E('td',{'class':'td'},e.from||e.to?(e.from||'—')+' → '+(e.to||'—'):'—'),
            E('td',{'class':'td'},[E('span',{'style':'display:inline-block;padding:3px 7px;border-radius:4px;color:white;background:'+color},labels[e.event]||e.event)]),
            E('td',{'class':'td','style':'white-space:normal;overflow-wrap:anywhere'},[
                E('div',{},explain(e)),E('details',{'data-event-key':key,'open':expanded.has(key)?'':null},[E('summary',{},'Технические подробности'),
                    E('div',{},e.backend+' / '+e.section),E('pre',{'style':'white-space:pre-wrap;overflow-wrap:anywhere'},e.detail)])])
        ]);
    });
}
return view.extend({
    load:function(){return Promise.all([statusRPC(),jobRPC()]);},
    render:function(initial){
        var state=initial[0], job=initial[1], busy=!!job.running;
        var summary=E('p',{'class':'pvf-summary'}), updated=E('p',{'class':'description'});
        var result=E('pre',{'style':'white-space:pre-wrap;max-height:22em;overflow:auto'});
        var resultBox=E('details',{},[E('summary',{},'Результат последней команды'),result]);
        var body=E('tbody',{},[]);
        var table=E('table',{'class':'table'},[E('thead',{},[E('tr',{'class':'tr'},['Время','Переход','Результат','Что произошло'].map(function(t){return E('th',{'class':'th'},t);}))]),body]);
        var count=E('summary',{},'Журнал операций');
        // Keep this element across refreshes so the user's expanded/collapsed state is preserved.
        var history=E('details',{'class':'pvf-history'},[count,E('p',{},'Новые записи сверху. Храним последние 200 операций в памяти до перезагрузки роутера.'),E('div',{'style':'overflow-x:auto'},[table])]);
        var buttons=[];
        function syncButtons(){buttons.forEach(function(b){b.disabled=busy;});}
        function refresh(d,j){
            state=d;job=j;busy=!!j.running;syncButtons();
            summary.textContent='Версия '+(d.version||'—')+' · Служба: '+(d.running?'работает':'остановлена')+' · Автозапуск: '+(d.enabled?'включён':'выключен')+' · Движок: '+(d.backend||'не определён')+' · Секция: '+d.section+' · Туннель: '+(d.current||'не выбран');
            if(d.error) summary.textContent+=' · '+d.error;
            else if(!d.runtime) summary.textContent+=' · Ожидаем готовности VPN-движка';
            else if(!d.current) summary.textContent+=' · Ожидаем VPN-режима секции';
            var expanded=new Set();
            if(body.querySelectorAll) Array.from(body.querySelectorAll('details[open]')).forEach(function(n){expanded.add(n.getAttribute('data-event-key'));});
            var rows=eventRows(d,expanded),next=E('tbody',{},rows.length?rows:[E('tr',{},[E('td',{'colspan':'4'},'Операций пока нет.')])]);
            table.replaceChild(next,body);body=next;
            count.textContent='Журнал операций ('+(d.events||[]).length+') — развернуть / свернуть';
            updated.textContent='Обновлено: '+new Date().toLocaleTimeString();
            if(j.action) result.textContent=(j.running?'Выполняется: ':j.code===0?'Готово: ':'Команда завершилась с ошибкой: ')+({start:'запуск службы',stop:'остановка службы',restart:'перезапуск службы',status:'проверка состояния',test:'проверка туннелей',config:'текущие настройки'}[j.action]||j.action)+'\n'+(j.output||'');
        }
        function pollOnce(){return Promise.all([statusRPC(),jobRPC()]).then(function(d){refresh(d[0],d[1]);});}
        function action(name){
            if(busy)return Promise.resolve();
            busy=true;syncButtons();resultBox.open=true;result.textContent='Выполняется…';
            return runRPC(name).then(function(r){if(!r.accepted)throw new Error(r.error||'Команда не принята');return pollOnce();})
                .catch(function(e){busy=false;syncButtons();result.textContent='Не удалось выполнить команду: '+e.message;});
        }
        function button(label,name,style){var b=E('button',{'class':'cbi-button '+(style||''),'click':function(){return action(name);}},label);buttons.push(b);return b;}
        var controls=E('div',{'class':'pvf-controls','style':'display:flex;gap:8px;flex-wrap:wrap;margin:16px 0'},[
            button('Запустить','start','cbi-button-apply'),button('Остановить','stop','cbi-button-negative'),
            button('Перезапустить','restart'),button('Статус','status'),button('Проверить туннели','test'),button('Настройки','config')]);
        var download=E('button',{'class':'cbi-button cbi-button-action','click':function(){
            download.disabled=true;
            return diagnosticsRPC().then(function(d){
                d.last_command=job;
                var url=URL.createObjectURL(new Blob([JSON.stringify(d,null,2)+'\n'],{type:'application/json;charset=utf-8'}));
                var a=E('a',{'href':url,'download':'vpn-failover-diagnostics-'+new Date().toISOString().replace(/[:.]/g,'-')+'.json'});
                document.body.appendChild(a);a.click();a.remove();setTimeout(function(){URL.revokeObjectURL(url);},1000);
            }).catch(function(e){resultBox.open=true;result.textContent='Не удалось скачать логи: '+e.message;})
                .finally(function(){download.disabled=false;});
        }},'Скачать логи для диагностики');
        refresh(state,job);
        poll.add(function(){return pollOnce().catch(function(){updated.textContent='Не удалось обновить данные. Показаны последние полученные сведения.';});},5);
        return E('div',{},[E('h2',{},'VPN Failover'),summary,controls,
            E('p',{'class':'description'},'«Запустить» также включает автозапуск. «Остановить» отключает его. Проверка туннелей не меняет выбранный VPN. Настройки показывают текущие параметры службы.'),
            updated,resultBox,E('div',{'style':'margin:16px 0'},[download,E('p',{'class':'description'},'Диагностический JSON для разбора проблемы: состояние службы, настройки и исходные технические сообщения. Без VPN-ключей и полных конфигураций.')]),history]);
    },
    handleSave:null,handleSaveApply:null,handleReset:null
});
