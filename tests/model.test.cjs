const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const file = path.join(__dirname, '../Model.js');
const M = {};
if (fs.existsSync(file)) vm.runInNewContext(fs.readFileSync(file, 'utf8').replace(/^\.pragma library\s*/, ''), M);
const clone = value => JSON.parse(JSON.stringify(value));
const port = (n = 3000, host = '127.0.0.1') => ({ id: `tcp:${host}:${n}`, address: host, port: n, exposure: host === '127.0.0.1' ? 'localhost' : 'all', process: 'vite', pid: 100, owner: 'dev', cwd: '/work/project', uptimeSeconds: 10, containerIds: [], database: null, protocol: 'http', state: 'running' });
const cid = 'a'.repeat(64);
const container = () => ({id: cid, name: 'web', image: 'node:22', state: 'running', publishedPorts: [port()], database: null});

// Behaves like the public ListModel mutation API; counts actual changes.
class List {
    constructor(rows = []) { this.rows = clone(rows); this.changes = 0; }
    get count() { return this.rows.length; }
    get(i) { return this.rows[i]; }
    append(row) { this.rows.push(clone(row)); this.changes++; }
    insert(i, row) { this.rows.splice(i, 0, clone(row)); this.changes++; }
    set(i, row) { this.rows[i] = clone(row); this.changes++; }
    remove(i) { this.rows.splice(i, 1); this.changes++; }
    move(from, to) { this.rows.splice(to, 0, this.rows.splice(from, 1)[0]); this.changes++; }
}

test('configuration defaults, invalid bounds and empty tabs recover safely', () => {
    assert.equal(typeof M.config, 'function', 'Model implementation missing');
    assert.equal(M.config({}).refreshInterval, 5);
    assert.equal(M.config({ refreshInterval: -1 }).refreshInterval, 5);
    assert.equal(M.config({ dockerEnabled: false }).dockerEnabled, false);
    assert.deepEqual(clone(M.config({ visibleTabs: '' }).tabs), ['Localhost']);
    assert.equal(M.validateSettings({ refreshInterval: 'x' }).length > 0, true);
    assert.equal(M.validateSettings({ hiddenPorts: '80,3000-3010' }).length, 0);
    assert.equal(M.validateSettings({ hiddenPorts: '80;rm' }).length > 0, true);
});

test('JSON envelope guards malformed, oversized and mismatched responses', () => {
    for (const raw of ['bad', '[]', JSON.stringify({schemaVersion: 2, kind: 'ports', data: {}})])
        assert.throws(() => M.decode(raw, 'ports'));
    assert.throws(() => M.decode(' '.repeat(3 * 1024 * 1024), 'ports'));
    const valid = {schemaVersion: 1, kind: 'ports', ok: true, errors: [], data: {ports: [port()]}};
    assert.equal(M.decode(JSON.stringify(valid), 'ports').data.ports[0].port, 3000);
    valid.data.ports[0].port = 'rm -rf';
    assert.throws(() => M.decode(JSON.stringify(valid), 'ports'));
});

test('merge keeps unchanged arrays and omitted sections, rejects forged endpoints', () => {
    const current = { ports: [port()], containers: [container()] };
    const next = M.merge(current, { ports: [port()] });
    assert.equal(next.ports, current.ports);
    assert.equal(next.containers, current.containers);
    const payload = {schemaVersion: 1, kind: 'ports', ok: true, errors: [], data: {ports: [port(3000, 'host/path')]}};
    assert.throws(() => M.decode(JSON.stringify(payload), 'ports'));
});

test('Docker publication merges with ss and internal ports never become listeners', () => {
    const rows = M.listeners({ports: [port()], containers: [container()]}, true);
    assert.equal(rows.length, 1);
    assert.deepEqual(clone(rows[0].containerIds), [cid]);
    const stopped = container(); stopped.state = 'exited';
    assert.equal(M.listeners({ports: [], containers: [stopped]}, true).length, 0);
    assert.equal(M.listeners({ports: [], containers: [container()]}, false).length, 0);
    const internal = container(); internal.publishedPorts = [];
    assert.equal(M.listeners({ports: [], containers: [internal]}, true).length, 0);
});

test('URLs allow numeric HTTP endpoints and IPv6 but never database or arbitrary schemes', () => {
    assert.equal(M.url(port()), 'http://127.0.0.1:3000/');
    assert.equal(M.url(port(80, '::1')), 'http://[::1]:80/');
    assert.equal(M.url(port(80, '0.0.0.0')), 'http://127.0.0.1:80/');
    assert.equal(M.url({...port(), database: 'Redis'}), '');
    assert.equal(M.url({...port(), protocol: 'javascript'}), '');
    assert.equal(M.url(port(80, '127.0.0.1@evil.com')), '');
    assert.equal(M.url({...port(), protocol: null}), '');
});

test('filter/search/sort applies hidden ranges, exposure and tab-specific states', () => {
    const state = {ports: [port(3000), port(5173), port(8080, '0.0.0.0')], containers: []};
    const cfg = M.config({hiddenPorts: '3000-3001', exposure: 'localhost'});
    assert.deepEqual(clone(M.rows(state, 'Localhost', '', 'all', cfg).map(r => r.id)), ['tcp:127.0.0.1:5173']);
    assert.equal(M.rows(state, 'Localhost', 'no-match', 'all', cfg).length, 0);
    assert.equal(M.rows({containers: [{...container(), state: 'exited'}]}, 'Docker', '', 'running', M.config({})).length, 0);
    assert.equal(M.rows({images: [{id:'image',tags:['postgres:17'],used:true,size:'12MB'}]}, 'Images', 'postgres', 'unused', M.config({})).length, 0);
});

test('incremental ListModel sync preserves identical rows and updates only changed rows', () => {
    const list = new List();
    const initial = [{id:'a', title:'A'}, {id:'b', title:'B'}];
    M.sync(list, initial);
    assert.equal(list.count, 2);
    list.changes = 0;
    M.sync(list, clone(initial));
    assert.equal(list.changes, 0);
    M.sync(list, [{id:'a', title:'updated'}, {id:'b',title:'B'}]);
    assert.equal(list.changes, 1);
    M.sync(list, [{id:'b',title:'B'}, {id:'c',title:'C'}]);
    assert.deepEqual(list.rows.map(r => r.id), ['b', 'c']);
});

test('poll scheduler never overlaps, slows down closed panels and defers inventory', () => {
    const cfg = M.config({});
    assert.equal(M.nextScope(10000, true, cfg, {}, true), '');
    assert.equal(M.nextScope(10000, true, cfg, {}, false), 'ports');
    assert.equal(M.nextScope(10000, true, cfg, {ports:10000}, false), 'docker');
    assert.equal(M.nextScope(10000, true, cfg, {ports:10000,docker:10000}, false), 'assets');
    assert.equal(M.nextScope(10000, false, cfg, {ports:5000,docker:5000}, false), '');
    assert.equal(M.nextScope(10000, true, M.config({dockerEnabled:false}), {ports:10000}, false), '');
});

test('database view includes stopped evidence and only configured SQLite files', () => {
    const state = {ports: [{...port(5432), database:'PostgreSQL'}],
        containers: [{...container(), state:'exited', database:'Redis', publishedPorts:[]}],
        sqlite: [{id:'sqlite:/work/app.db', name:'app.db', path:'/work/app.db', database:'SQLite',state:'configured'}]};
    const rows = M.rows(state, 'Databases', '', 'all', M.config({}));
    assert.equal(rows.length, 3);
    assert.equal(rows.filter(r => r.state === 'exited').length, 1);
});

test('malformed nested image/volume fields and cross-scope sections are rejected', () => {
    const wrap = data => JSON.stringify({schemaVersion:1,kind:'assets',ok:true,errors:[],data});
    assert.throws(() => M.decode(wrap({images:[{id:'x',tags:{},used:false}]}), 'assets'));
    assert.throws(() => M.decode(wrap({volumes:[{id:'x',containers:{},destinations:[]}]}), 'assets'));
    assert.throws(() => M.decode(wrap({ports:[port()]}), 'assets'));
});

test('Docker published endpoints cannot conceal missing address or container lists', () => {
    const bad = {...port(), containerIds:{}};
    assert.throws(() => M.decode(JSON.stringify({schemaVersion:1,kind:'ports',ok:true,errors:[],data:{ports:[bad]}}), 'ports'));
});

test('mapped IPv6 endpoints coexist with other listeners and yield valid URLs', () => {
    const mapped = port(3001, '::ffff:127.0.0.1');
    const payload = {schemaVersion:1,kind:'ports',ok:true,errors:[],data:{ports:[port(),mapped]}};
    assert.equal(M.decode(JSON.stringify(payload), 'ports').data.ports.length, 2);
    assert.equal(M.url(mapped), 'http://[::ffff:127.0.0.1]:3001/');
});

test('mixed IPv6 addresses preserve the numeric URL boundary', () => {
    assert.equal(M.url(port(8080, '64:ff9b::192.0.2.1')), 'http://[64:ff9b::192.0.2.1]:8080/');
    for (const host of ['::ffff:256.0.0.1', '::ffff:127.0.0', '::ffff:127.0.0.1/evil',
        '::ffff:127.0.0.1@evil.com', '::ffff:127.0.0.1?x']) {
        assert.equal(M.url(port(8080, host)), '', host);
    }
});

test('slow port queries cannot starve never-queried Docker scopes', () => {
    const cfg = M.config({refreshInterval:2});
    const last = {};
    const observed = [];
    for (let now = 0; now < 14000; now += 2100) {
        const scope = M.nextScope(now, true, cfg, last, false);
        if (scope) { observed.push(scope); last[scope] = now; }
    }
    assert.ok(observed.includes('docker'));
    assert.ok(observed.includes('assets'));
});

test('overdue scopes keep making progress after their first query', () => {
    const cfg = M.config({refreshInterval:2});
    const last = {ports:1000, docker:2000, assets:3000};
    const observed = [];
    for (let now = 70000; now <= 160000; now += 30000) {
        const scope = M.nextScope(now, true, cfg, last, false);
        observed.push(scope);
        last[scope] = now;
    }
    assert.deepEqual(observed, ['ports', 'docker', 'assets', 'ports']);
    assert.equal(M.nextScope(70000, false, cfg, {ports:70000,docker:70000}, false), '');
    assert.equal(M.nextScope(70000, true, M.config({dockerEnabled:false}), {ports:70000}, false), '');
});

// Execute the widget's actual JS handlers without loading a desktop shell.
// Qt objects at the boundary are replaced only for process/timer side effects.
function qmlHandler(source, marker, signature, context) {
    const start = source.indexOf('{', source.indexOf(marker));
    for (let end = source.indexOf('}', start); end !== -1; end = source.indexOf('}', end + 1)) {
        let script;
        try {
            script = new vm.Script('(' + signature + source.slice(start, end + 1) + ')');
        } catch (error) {
            if (error instanceof SyntaxError) continue;
            throw error;
        }
        return script.runInContext(context);
    }
    throw new Error('Cannot compile QML handler: ' + marker);
}

function widgetHarness(cancelled) {
    const source = fs.readFileSync(path.join(__dirname, '../BarWidget.qml'), 'utf8');
    const effects = {watchdogStops:0, forceStops:0, forceStarts:0};
    const context = vm.createContext({
        Model:M, requestScope:'logs', requestGeneration:1, generation:1,
        requestLogToken:1, timedOut:false, received:false, errors:{}, busy:true,
        lastSuccess:{}, worker:{running:true},
        logs:{generation:cancelled ? 2 : 1, accept:() => !cancelled,
            clear() { this.generation++; }},
        watchdog:{stop() { effects.watchdogStops++; }},
        forceStop:{stop() { effects.forceStops++; }, restart() { effects.forceStarts++; }}
    });
    context.root = context;
    for (const match of source.matchAll(/^    function (\w+)\(([^)]*)\)\s*\{/gm)) {
        context[match[1]] = qmlHandler(source, match[0], 'function(' + match[2] + ')', context);
    }
    context.exited = qmlHandler(source, 'onExited: function (exitCode, exitStatus)',
        'function(exitCode, exitStatus)', context);
    context.timeout = qmlHandler(source.slice(source.indexOf('id: watchdog')), 'onTriggered:',
        'function()', context);
    return {context, effects};
}

test('cancelled log responses and failed exits stay silent while releasing the worker', () => {
    for (const raw of ['malformed JSON', JSON.stringify({schemaVersion:1,kind:'logs',ok:false,
        errors:['Docker unavailable'],data:{}})]) {
        const {context, effects} = widgetHarness(true);
        context.consume(raw);
        context.exited(1, 0);
        assert.deepEqual(clone(context.errors), {});
        assert.equal(context.received, true);
        assert.equal(context.busy, false);
        assert.equal(effects.watchdogStops, 1);
        assert.equal(effects.forceStops, 1);
    }
});

test('cancelled log timeouts stop workers without adding a stale error', () => {
    const {context, effects} = widgetHarness(true);
    context.timeout();
    assert.equal(context.timedOut, true);
    assert.equal(context.worker.running, false);
    assert.equal(effects.forceStarts, 1);
    assert.deepEqual(clone(context.errors), {});
    context.exited(1, 0);
    assert.equal(context.busy, false);
});

test('active log errors and timeouts still reach the widget', () => {
    const failed = widgetHarness(false).context;
    failed.consume(JSON.stringify({schemaVersion:1,kind:'logs',ok:false,
        errors:['Docker unavailable'],data:{}}));
    failed.exited(1, 0);
    assert.equal(failed.errors.logs, 'Docker unavailable');
    assert.equal(failed.busy, false);
    const timed = widgetHarness(false).context;
    timed.timeout();
    assert.ok(timed.errors.logs.includes('timeout'));
    assert.equal(timed.worker.running, false);
});

test('leaving logs clears a previous log error without clearing inventory errors', () => {
    const {context} = widgetHarness(false);
    context.errors = {logs:'Docker unavailable', ports:'Port query failed'};
    context.clearLogs();
    assert.equal(context.errors.logs, '');
    assert.equal(context.errors.ports, 'Port query failed');
    context.exited(1, 0);
    assert.equal(context.errors.logs, '');
    assert.equal(context.busy, false);
});
