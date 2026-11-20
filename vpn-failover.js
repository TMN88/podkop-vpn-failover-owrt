"use strict";
'require view';
'require rpc';
'require poll';

var statusRPC = rpc.declare({object:'vpn-failover',method:'status',expect:{}});
var jobRPC = rpc.declare({object:'vpn-failover',method:'job',expect:{}});
var runRPC = rpc.declare({object:'vpn-failover',method:'run',params:['action'],expect:{}});
var diagnosticsRPC = rpc.declare({object:'vpn-failover',method:'diagnostics',expect:{}});
var labels = {success:'Успешно',rollback:'Откат выполнен',rollback_failed:'Ошибка отката',notice:'Информация',warning:'Предупреждение',err:'Ошибка'};
Object.assign(labels,{CURRENT_FAILED:'Туннель не отвечает',RUNTIME_DOWN:'Движок остановлен',CANDIDATE_HEALTHY:'Резерв проверен',SWITCH_APPLIED:'Настройка применена',BACKEND_STARTED:'Обход запущен',SINGBOX_STARTED:'Движок запущен',PATH_VERIFIED:'Маршрут проверен',RECOVERED:'Обход восстановлен',ROLLBACK:'Возврат настройки',NO_HEALTHY_RESERVE:'Нет рабочего резерва',PAUSED:'Пауза',CONFIG_CHANGED_EXTERNALLY:'Настройки изменены вручную',RECOVERY_FAILED:'Не удалось восстановить'});
var states={PAUSED:'Пауза для обслуживания',OBSERVING:'Наблюдение',PROBING:'Проверяем туннели',APPLYING:'Применяем резерв',STARTING_BACKEND:'Восстанавливаем движок',VERIFYING:'Проверяем обход',RECOVERED:'Обход восстановлен',ROLLING_BACK:'Возвращаем настройку',WAITING_NETWORK:'Проверка сети пока недоступна',NO_HEALTHY_RESERVE:'Рабочих резервов нет',RECOVERY_FAILED:'Восстановление не подтверждено'};
var reasons={PATH_TEST_UNAVAILABLE:'Движок не предоставляет безопасную проверку маршрута секции',CONFIG_CHANGED_EXTERNALLY:'Настройки изменены вручную',RULESET_FAILURE:'Не удалось загрузить списки правил',DNS_FAILURE:'Не удалось получить независимый ответ DNS',CONFIG_INVALID:'Ошибка конфигурации движка',CONFIG_COMPATIBILITY:'Версии движка и конфигурации несовместимы',NO_HANDSHAKE:'Нет рукопожатия с VPN-сервером',INTERFACE_DOWN:'VPN-интерфейс не работает',HTTPS_FAILURE:'HTTPS через туннель не подтвердился',OTHER_BACKEND_ACTIVE:'Работает другой движок обхода',SECTION_NOT_VPN:'Выбрана секция без VPN',DEADLINE:'Истекло время восстановления',BACKEND_AMBIGUOUS:'Нужно явно выбрать движок обхода'};
function backendName(name){return {podkop:'Podkop',forkop:'Forkop',forkozz:'Forkozz (NetShift)'}[name]||'Обход не определён';}
function checkTime(check){
    if(!check||!check.time)return 'ещё не выполнялась';
    var d=new Date(check.time);
    return Number.isNaN(d.getTime())?check.time:d.toLocaleString();
}
function contextLines(text,backend){
    var prefix='['+backendName(backend)+'] ';
    return String(text||'').split('\n').map(function(line){
        return /^\[(Podkop|Forkop|Forkozz \(NetShift\)|Обход не определён)\] /.test(line)?line:prefix+line;
    }).join('\n');
}
function bypassStatus(d){
    if(d.error)return 'Не определён / ошибка настройки';
    if(d.backend_installed===false)return 'Служба выбранного обхода не найдена';
    if(!d.runtime)return 'Не работает: sing-box остановлен или не готов';
    if(d.check_fresh&&d.last_active_check&&d.last_active_check.code===1)return 'Активный туннель не прошёл последнюю проверку — обход не подтверждён';
    if(d.ready&&d.check_fresh&&d.last_active_check&&d.last_active_check.result==='HEALTHY')return 'Работает — маршрут подтверждён последней проверкой';
    if(d.last_active_check&&d.check_fresh===false)return 'Последняя проверка устарела — работа сейчас не подтверждена';
    return 'sing-box запущен — работоспособность маршрута пока не подтверждена';
}

function explain(e) {
    var s=e.detail || '', m;
    var recoveryText={CURRENT_FAILED:'Текущий туннель не прошёл проверку. Ошибка движка учитывается отдельно.',RUNTIME_DOWN:'Туннель работает, но движок или его маршрут не готов. Восстанавливаем обход через тот же туннель.',CANDIDATE_HEALTHY:'Резерв '+e.to+' подтвердил соединение и передачу данных.',SWITCH_APPLIED:'Выбран '+e.to+'. Проверка восстановления ещё продолжается.',BACKEND_STARTED:'Команда запуска или применения выполнена. Проверяем движок и маршрут.',SINGBOX_STARTED:'Движок запущен; это ещё не подтверждение восстановления.',PATH_VERIFIED:'Проверен HTTPS через маршрут выбранной секции.',RECOVERED:'Обход восстановлен через '+e.to+'.',ROLLBACK:'Возвращена настройка прежнего туннеля. Работоспособность проверяется отдельно.',NO_HEALTHY_RESERVE:'Подтверждённого рабочего резерва нет. Повторная попытка после выдержки.',PAUSED:'Автоматические переключения и запуск движка приостановлены.',CONFIG_CHANGED_EXTERNALLY:'Ты изменил настройки во время проверки. Служба сохраняет твой выбор.',RECOVERY_FAILED:'Восстановление не подтверждено. Причина указана в подробностях; логи можно скачать.'};
    if(recoveryText[e.event])return recoveryText[e.event];
    if(e.event==='success') return 'Переключились на '+e.to+'. Привязка и доступ в интернет проверены.';
    if(e.event==='rollback') return 'Вернулись на '+e.to+': резерв не прошёл проверку.';
    if(e.event==='rollback_failed') return 'Не удалось подтвердить возврат на '+e.to+'. Нужна диагностика.';
    if(s.indexOf('Switching ')===0) return 'Начинаем переход с '+e.from+' на '+e.to+'.';
    if(s.indexOf('Failover completed successfully')===0) return 'Переход завершён: '+e.to+'.';
    if((m=s.match(/^Health-check failed for ([^:]+): (\d+)\/(\d+)/))) return 'Туннель '+m[1]+' не отвечает. Неудачных проверок: '+m[2]+' из '+m[3]+'.';
    if(s.indexOf('Confirmed VPN failure')===0 || s.indexOf('Confirmed unhealthy')===0 || s.indexOf('Confirmed unavailable')===0) return 'Отказ текущего туннеля подтверждён. Начинаем поиск рабочего резерва.';
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
    if(s.indexOf('No healthy non-quarantined')===0) return 'Свежих рабочих резервов нет. Проверим ранее отказавшие туннели ещё раз.';
    if(s.indexOf('No healthy')===0) return 'Рабочих резервных туннелей пока нет. Повторим проверку позже.';
    if(s.indexOf('recovered')>=0) return 'Связь через текущий туннель восстановилась.';
    if(s.indexOf('externally')>=0 || s.indexOf('outside failover')>=0) return 'Выбор туннеля изменён вне службы. Сохраняем новый выбор.';
    return 'Техническое сообщение. Подробности доступны ниже и в скачиваемом логе.';
}
function eventRows(data,expanded) {
    expanded=expanded||new Set();
    return (data.events || []).map(function(e) {
        var key=e.time+'|'+e.event+'|'+e.detail;
        var color=(e.event==='success'||e.event==='RECOVERED')?'#23783d':(e.event==='err'||e.event==='rollback_failed'||e.event==='RECOVERY_FAILED'?'#a32626':'#705300');
        return E('tr',{'class':'tr'},[
            E('td',{'class':'td'},e.time),
            E('td',{'class':'td'},backendName(e.backend)),
            E('td',{'class':'td'},e.from||e.to?(e.from||'—')+' → '+(e.to||'—'):'—'),
            E('td',{'class':'td'},[E('span',{'style':'display:inline-block;padding:3px 7px;border-radius:4px;color:white;background:'+color},labels[e.event]||e.event)]),
            E('td',{'class':'td','style':'white-space:normal;overflow-wrap:anywhere'},[
                E('div',{},'['+backendName(e.backend)+'] '+explain(e)),E('details',{'data-event-key':key,'open':expanded.has(key)?'':null},[E('summary',{},'Технические подробности'),
                    E('div',{},backendName(e.backend)+' / '+e.section),E('pre',{'style':'white-space:pre-wrap;overflow-wrap:anywhere'},contextLines(e.detail,e.backend))])])
        ]);
    });
}
return view.extend({
    load:function(){return Promise.all([statusRPC(),jobRPC()]);},
    render:function(initial){
        var state=initial[0], job=initial[1], busy=!!job.running;
        var summary=E('p',{'class':'pvf-summary'}), updated=E('p',{'class':'description'});
        var bypass=E('strong',{'class':'pvf-backend-name'}), bypassState=E('p',{'class':'pvf-backend-status'});
        var engineState=E('p',{'class':'pvf-engine-status'}), lastCheck=E('p',{'class':'pvf-last-check'});
        var bypassPanel=E('div',{'class':'cbi-section pvf-backend-panel','style':'padding:16px;border-left:5px solid #777'},[
            E('h3',{},['Текущий обход: ',bypass]),bypassState,engineState,lastCheck]);
        var result=E('pre',{'style':'white-space:pre-wrap;max-height:22em;overflow:auto'});
        var resultBox=E('details',{},[E('summary',{},'Результат последней команды'),result]);
        var body=E('tbody',{},[]);
        var table=E('table',{'class':'table'},[E('thead',{},[E('tr',{'class':'tr'},['Время','Обход','Переход','Результат','Что произошло'].map(function(t){return E('th',{'class':'th'},t);}))]),body]);
        var count=E('summary',{},'Журнал операций');
        // Keep this element across refreshes so the user's expanded/collapsed state is preserved.
        var history=E('details',{'class':'pvf-history'},[count,E('p',{},'Новые записи сверху. Храним последние 200 операций в памяти до перезагрузки роутера.'),E('div',{'style':'overflow-x:auto'},[table])]);
        var buttons=[];
        function syncButtons(){buttons.forEach(function(b){b.disabled=busy;});}
        function refresh(d,j){
            state=d;job=j;busy=!!j.running;syncButtons();
            var prefix='['+backendName(d.backend)+'] ';
            bypass.textContent=backendName(d.backend);
            bypassState.textContent=prefix+'Состояние обхода: '+bypassStatus(d);
            var verified=d.runtime&&d.ready&&d.check_fresh&&d.last_active_check&&d.last_active_check.result==='HEALTHY'&&d.last_active_check.code===0&&!d.error&&d.backend_installed!==false;
            if(bypassState.style)bypassState.style.color=verified?'#23783d':!d.runtime||d.error||d.check_fresh&&d.last_active_check&&d.last_active_check.code===1?'#a32626':'#705300';
            engineState.textContent=prefix+'Служба/правила обхода: '+(d.backend_active?'обнаружены':'не подтверждены')+' · sing-box: '+(d.runtime?'работает':'не готов');
            lastCheck.textContent=prefix+'Последняя проверка активного туннеля: '+checkTime(d.last_active_check)+
                (d.last_active_check?' · '+d.last_active_check.interface+' · '+(d.last_active_check.result==='HEALTHY'?'туннель отвечает':(reasons[d.last_active_check.result]||d.last_active_check.result)):'')+
                (d.last_active_check&&d.check_fresh===false?' · данные устарели':'');
            summary.textContent=prefix+'Версия '+(d.version||'—')+' · Failover: '+(d.running?'работает':'остановлен')+' · Автозапуск: '+(d.enabled?'включён':'выключен')+' · Секция: '+d.section+' · Туннель: '+(d.current||'не выбран');
            if(d.error) summary.textContent+=' · '+d.error;
            else if(d.paused) summary.textContent+=' · Пауза: движок не запускаем';
            else if(!d.runtime) summary.textContent+=' · Движок остановлен; активная служба попробует восстановить обход';
            else if(!d.current) summary.textContent+=' · Ожидаем VPN-режима секции';
            summary.textContent+=' · '+(states[d.state]||'Восстановление ещё не подтверждено')+(d.reason?' · '+(reasons[d.reason]||'Причина указана в технических подробностях'):'');
            summary.textContent+=' · '+(d.paused?'Наблюдение на паузе':'Наблюдение: '+(d.running?'включено':'выключено'));
            if(d.operation_id&&d.probing)summary.textContent+=' · Проверяем: '+d.probing;
            var expanded=new Set();
            if(body.querySelectorAll) Array.from(body.querySelectorAll('details[open]')).forEach(function(n){expanded.add(n.getAttribute('data-event-key'));});
            var rows=eventRows(d,expanded),next=E('tbody',{},rows.length?rows:[E('tr',{},[E('td',{'colspan':'5'},'Операций пока нет.')])]);
            table.replaceChild(next,body);body=next;
            count.textContent='Журнал операций ('+(d.events||[]).length+') — развернуть / свернуть';
            updated.textContent=prefix+'Данные страницы обновлены: '+new Date().toLocaleTimeString()+' (это не время проверки туннеля)';
            if(j.action) result.textContent=contextLines((j.running?'Выполняется: ':j.code===0?'Готово: ':'Команда завершилась с ошибкой: ')+({start:'запуск службы',stop:'остановка службы',restart:'перезапуск службы',status:'проверка состояния',test:'проверка туннелей',config:'текущие настройки',pause:'пауза',resume:'продолжение наблюдения',recover:'проверка и восстановление',reset:'сброс счётчиков'}[j.action]||j.action)+'\n'+(j.output||''),j.backend);
        }
        function pollOnce(){return Promise.all([statusRPC(),jobRPC()]).then(function(d){refresh(d[0],d[1]);});}
        function action(name){
            if(busy)return Promise.resolve();
            busy=true;syncButtons();resultBox.open=true;result.textContent=contextLines('Выполняется…',state.backend);
            return runRPC(name).then(function(r){if(!r.accepted)throw new Error(r.error||'Команда не принята');return pollOnce();})
                .catch(function(e){busy=false;syncButtons();result.textContent=contextLines('Не удалось выполнить команду: '+e.message,state.backend);});
        }
        function button(label,name,style){var b=E('button',{'class':'cbi-button '+(style||''),'click':function(){return action(name);}},label);buttons.push(b);return b;}
        var controls=E('div',{'class':'pvf-controls','style':'display:flex;gap:8px;flex-wrap:wrap;margin:16px 0'},[
            button('Запустить','start','cbi-button-apply'),button('Остановить','stop','cbi-button-negative'),
            button('Перезапустить','restart'),button('Статус','status'),button('Проверить туннели','test'),button('Настройки','config'),
            button('Пауза','pause'),button('Продолжить','resume'),button('Восстановить сейчас','recover'),button('Сбросить счётчики','reset')]);
        var download=E('button',{'class':'cbi-button cbi-button-action','click':function(){
            download.disabled=true;
            return diagnosticsRPC().then(function(d){
                d.last_command=job;
                var url=URL.createObjectURL(new Blob([JSON.stringify(d,null,2)+'\n'],{type:'application/json;charset=utf-8'}));
                var a=E('a',{'href':url,'download':'vpn-failover-diagnostics-'+new Date().toISOString().replace(/[:.]/g,'-')+'.json'});
                document.body.appendChild(a);a.click();a.remove();setTimeout(function(){URL.revokeObjectURL(url);},1000);
            }).catch(function(e){resultBox.open=true;result.textContent=contextLines('Не удалось скачать логи: '+e.message,state.backend);})
                .finally(function(){download.disabled=false;});
        }},'Скачать логи для диагностики');
        refresh(state,job);
        poll.add(function(){return pollOnce().catch(function(){updated.textContent=contextLines('Не удалось обновить данные. Показаны последние полученные сведения.',state.backend);});},5);
            return E('div',{},[E('h2',{},'VPN Failover'),bypassPanel,summary,controls,
            E('p',{'class':'description'},'Перед обслуживанием поставь Failover на паузу или останови его службу, затем останавливай VPN-движок. Без паузы активная служба восстанавливает остановленный движок. «Продолжить» снимает паузу; «Запустить» включает автозапуск Failover, «Остановить» отключает его. Открытие страницы ничего не запускает.'),
            updated,resultBox,E('div',{'style':'margin:16px 0'},[download,E('p',{'class':'description'},'Диагностический JSON для разбора проблемы: состояние службы, настройки и исходные технические сообщения. Без VPN-ключей и полных конфигураций.')]),history]);
    },
    handleSave:null,handleSaveApply:null,handleReset:null
});
