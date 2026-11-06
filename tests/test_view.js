const fs = require('fs');
const assert = require('assert');
const source = fs.readFileSync(require('path').join(__dirname, '..', 'vpn-failover.js'), 'utf8');
function E(tag, attrs, children) {
    return { tag, attrs, children, textContent: '', appendChild(child) { this.children.push(child); },
        replaceChild(child, old) { const i = this.children.indexOf(old); this.children[i] = child; } };
}
let tick;
let response;
const read = () => response instanceof Error ? Promise.reject(response) : Promise.resolve(response);
const view = new Function('view', 'rpc', 'poll', 'E', source)(
    { extend: x => x }, { declare: () => read }, { add: (f, interval) => { tick = f; assert.equal(interval, 5); } }, E);
const injection = '<img src=x onerror=alert(1)>';
const data = { backend: 'forkozz', section: 'work', current: 'awg1', error: '', events: [
    { time: '2026-11-06', backend: 'forkozz', section: 'work', from: 'awg0', to: 'awg1', event: 'success', detail: injection }
] };
(async () => {
    const page = view.render(data);
    assert(page.children[1].textContent.includes('forkozz'));
    const table = page.children[4].children;
    assert.equal(table.children[1].children[0].children[4].children, injection);
    response = { ...data, events: [] };
    await tick();
    assert.equal(table.children[1].children[0].children[0].attrs.colspan, '5');
    response = new Error('network');
    await tick();
    assert(page.children[3].textContent.includes('Не удалось'));
    assert.equal(view.handleSave, null);
    console.log('PASS: view rendering, plain text escaping, empty history, polling, failed refresh');
})().catch(e => { console.error(e); process.exitCode = 1; });
