'use strict';
'require view';
'require rpc';
'require poll';

var readStatus = rpc.declare({ object: 'vpn-failover', method: 'status', expect: {} });
var labels = { success: 'Успешно', rollback: 'Откат выполнен', rollback_failed: 'Ошибка отката',
    notice: 'Операция', warning: 'Предупреждение', err: 'Ошибка' };

function rows(data) {
    return (data.events || []).map(function(e) {
        var color = e.event === 'success' ? '#18743a' :
            (e.event === 'err' || e.event === 'rollback_failed' ? '#b32424' : '#755300');
        return E('tr', { 'class': 'tr' }, [
            E('td', { 'class': 'td' }, e.time),
            E('td', { 'class': 'td' }, e.backend + ' / ' + e.section),
            E('td', { 'class': 'td' }, e.from || e.to ? (e.from || '—') + ' → ' + (e.to || '—') : '—'),
            E('td', { 'class': 'td', 'style': 'color:' + color }, labels[e.event] || e.event),
            E('td', { 'class': 'td', 'style': 'white-space:normal;overflow-wrap:anywhere' }, e.detail)
        ]);
    });
}

return view.extend({
    load: function() { return readStatus(); },
    render: function(data) {
        var summary = E('p');
        var updated = E('p', { 'class': 'description' });
        var body = E('tbody', {}, []);
        var table = E('table', { 'class': 'table' }, [E('thead', {}, [E('tr', { 'class': 'tr table-titles' },
            ['Время', 'Движок / секция', 'Переход', 'Результат', 'Подробности'].map(function(t) {
                return E('th', { 'class': 'th' }, t);
            }))]), body]);
        function refresh(d) {
            summary.textContent = d.error || ('Движок: ' + d.backend + ' · Секция: ' + d.section + ' · Туннель: ' + (d.current || 'не выбран'));
            var entries = rows(d);
            var next = E('tbody', {}, entries.length ? entries : [E('tr', { 'class': 'tr' },
                [E('td', { 'class': 'td', 'colspan': '5' }, 'Операций пока нет.')])]);
            table.replaceChild(next, body);
            body = next;
            updated.textContent = 'Обновлено: ' + new Date().toLocaleTimeString();
        }
        refresh(data);
        poll.add(function() {
            return readStatus().then(refresh).catch(function() {
                updated.textContent = 'Не удалось обновить журнал. Показаны последние полученные данные.';
            });
        }, 5);
        return E('div', {}, [E('h2', {}, 'Журнал переключений VPN'), summary,
            E('p', {}, 'Последние 200 операций, новые сверху. Журнал хранится в памяти и очищается при перезагрузке роутера.'),
            updated, E('div', { 'style': 'overflow-x:auto' }, table)]);
    },
    handleSave: null, handleSaveApply: null, handleReset: null
});
