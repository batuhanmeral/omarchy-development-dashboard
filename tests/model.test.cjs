const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const file = path.join(__dirname, '../Model.js');
const M = {};
if (fs.existsSync(file)) vm.runInNewContext(fs.readFileSync(file, 'utf8').replace(/^\.pragma library\s*/, ''), M);
const clone = value => JSON.parse(JSON.stringify(value));
const port = (n = 3000, host = '127.0.0.1') => ({ id: `tcp:${host}:${n}`, address: host, port: n, exposure: host === '127.0.0.1' ? 'localhost' : 'all', process: 'vite', pid: 100, owner: 'dev', cwd: '/work/project', startedAt: 1700000000, containerIds: [], database: null, protocol: 'http', state: 'running' });
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
    assert.deepEqual(clone(M.config({ settingsVersion:2, visibleTabs: '' }).tabs), ['Localhost']);
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
    assert.equal(M.nextScope(10000, true, M.config({dockerEnabled:false}), {ports:10000,tools:10000,legacy:10000}, false), '');
});

test('database view includes stopped evidence and only configured SQLite files', () => {
    const state = {ports: [{...port(5432), database:'PostgreSQL'}],
        containers: [{...container(), state:'exited', database:'Redis', publishedPorts:[]}],
        sqlite: [{id:'sqlite:/work/app.db', name:'app.db', path:'/work/app.db', database:'SQLite',state:'configured'}]};
    const rows = M.rows(state, 'Databases', '', 'all', M.config({}));
    assert.equal(rows.length, 3);
    assert.equal(rows.filter(r => r.rowState === 'exited').length, 1);
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
    const last = {ports:1000, docker:2000, assets:3000, tools:70000, legacy:70000};
    const observed = [];
    for (let now = 70000; now <= 160000; now += 30000) {
        const scope = M.nextScope(now, true, cfg, last, false);
        observed.push(scope);
        last[scope] = now;
    }
    assert.deepEqual(observed, ['ports', 'docker', 'assets', 'ports']);
    assert.equal(M.nextScope(70000, false, cfg, {ports:70000,docker:70000}, false), '');
    assert.equal(M.nextScope(70000, true, M.config({dockerEnabled:false}), {ports:70000,tools:70000,legacy:70000}, false), '');
});

test('zoned IPv4 listeners such as systemd-resolved do not reject the whole response', () => {
    const stub = {...port(53, '127.0.0.53%lo'), process: 'Unknown', pid: null, protocol: null};
    const payload = {schemaVersion:1,kind:'ports',ok:true,errors:[],data:{ports:[port(), stub]}};
    assert.equal(M.decode(JSON.stringify(payload), 'ports').data.ports.length, 2);
    assert.equal(M.url(stub, 'http'), 'http://127.0.0.53:53/');
    assert.equal(M.addressText(stub), '127.0.0.53%lo:53');
    for (const host of ['127.0.0.1%lo/x', '127.0.0.1%', '256.0.0.1%lo', '127.0.0.1%lo@evil'])
        assert.throws(() => M.decode(JSON.stringify({...payload, data:{ports:[port(53, host)]}}), 'ports'), host);
});

test('collector outcomes separate results, diagnostics, crashes and timeouts', () => {
    const ok = JSON.stringify({schemaVersion:1,kind:'ports',ok:true,errors:[],data:{ports:[port()]}});
    assert.equal(M.outcome('ports', ok, 0, false).error, '');
    assert.equal(M.outcome('ports', ok, 0, false).result.data.ports.length, 1);
    assert.match(M.outcome('ports', ok, 0, true).error, /timed out/);
    assert.equal(M.outcome('ports', ok, 0, true).result, null);
    assert.match(M.outcome('ports', '', 127, false).error, /exit 127/);
    assert.match(M.outcome('ports', undefined, 1, false).error, /exit 1/);
    assert.match(M.outcome('ports', 'malformed JSON', 0, false).error, /Invalid collector response/);
    assert.match(M.outcome('docker', ok, 0, false).error, /Invalid collector response/);
    const failed = JSON.stringify({schemaVersion:1,kind:'docker',ok:false,errors:['docker unavailable'],data:{dockerStatus:'unavailable'}});
    const outcome = M.outcome('docker', failed, 1, false);
    assert.equal(outcome.error, 'docker unavailable');
    assert.equal(outcome.result.data.dockerStatus, 'unavailable');
    assert.match(M.outcome('ports', ok, 3, false).error, /exit 3/);
});

test('stale jobs are recognised after settings changes and cancelled log requests', () => {
    assert.equal(M.current(null, 1, 1), false);
    assert.equal(M.current({scope:'ports', generation:1, logToken:0}, 1, 9), true);
    assert.equal(M.current({scope:'ports', generation:1, logToken:0}, 2, 9), false);
    assert.equal(M.current({scope:'logs', generation:1, logToken:4}, 1, 4), true);
    assert.equal(M.current({scope:'logs', generation:1, logToken:4}, 1, 5), false);
});

test('rows carry a scannable lead, tone and exposure instead of a text blob', () => {
    const exposed = {...port(8080, '0.0.0.0'), process:'node'};
    const lan = {...port(9000, '192.168.1.5'), exposure:'lan'};
    const rows = M.rows({ports:[port(), exposed, lan]}, 'Localhost', '', 'all', M.config({}));
    assert.deepEqual(clone(rows.map(r => [r.lead, r.badge, r.tone])),
        [['3000','local','info'], ['8080','exposed','urgent'], ['9000','lan','warn']]);
    assert.equal(rows[0].title, 'vite');
    assert.match(rows[0].subtitle, /127\.0\.0\.1/);
    assert.equal(M.rows({ports:[port(), exposed, lan]}, 'Localhost', '', 'lan', M.config({})).length, 2);
    assert.equal(M.rows({ports:[port(), exposed, lan]}, 'Localhost', '', 'localhost', M.config({})).length, 1);
    assert.equal(M.rows({ports:[port(), exposed]}, 'Localhost', 'NODE', 'all', M.config({})).length, 1);
    const containers = [{...container(), health:'unhealthy'}, {...container(), id:'b'.repeat(64), name:'db', state:'exited', publishedPorts:[]}];
    const docker = M.rows({containers}, 'Docker', '', 'all', M.config({sortBy:'name'}));
    assert.deepEqual(clone(docker.map(r => [r.title, r.badge, r.tone])), [['db','exited','dim'], ['web','unhealthy','urgent']]);
    const images = M.rows({images:[{id:'sha256:'+'c'.repeat(64),tags:['<none>:<none>'],used:false,size:'1MB'}],
        volumes:[{id:'volume:data',name:'data',containers:['db'],destinations:['/var/lib'],mountpoint:'/x'}]}, 'Images', '', 'all', M.config({}));
    // Images come before volumes, whose generated names would otherwise crowd the top.
    assert.deepEqual(clone(images.map(r => [r.title, r.badge, r.tone])), [['untagged','unused','dim'], ['data','attached','info']]);
});

test('facts describe each kind without unknown noise and stay copyable', () => {
    const now = 1700000000 + 3 * 3600 + 120;
    const row = M.rows({ports:[{...port(), cwd:'/work/app'}]}, 'Localhost', '', 'all', M.config({}))[0];
    const facts = clone(M.facts(row, now));
    const value = label => (facts.find(f => f.label === label) || {}).value;
    assert.equal(value('Address'), '127.0.0.1:3000');
    assert.equal(value('Exposure'), 'This machine only');
    assert.equal(value('Process'), 'vite (pid 100)');
    assert.equal(value('Running for'), '3h 2m');
    assert.equal(value('Working directory'), '/work/app');
    assert.equal(value('Container'), undefined);
    const anonymous = M.rows({ports:[{...port(53), process:'Unknown', pid:null, owner:'Unknown', cwd:null, startedAt:null, protocol:null}]}, 'Localhost', '', 'all', M.config({}))[0];
    assert.equal(anonymous.title, 'Unknown process');
    assert.deepEqual(clone(M.facts(anonymous, now).map(f => f.label)), ['Address', 'Exposure', 'Process']);
    const dock = M.rows({containers:[{...container(), cpu:'0.5%', memory:'10MiB / 1GiB', restart:'always', compose:'shop'}]}, 'Docker', '', 'all', M.config({}))[0];
    const dockFacts = clone(M.facts(dock, now));
    assert.equal(dockFacts.find(f => f.label === 'ID').value, cid.slice(0, 12));
    assert.equal(dockFacts.find(f => f.label === 'ID').copy, cid);
    assert.equal(dockFacts.find(f => f.label === 'Published').value, '127.0.0.1:3000');
    assert.deepEqual(clone(M.facts({raw:'not json', kind:'port'}, now)), []);
});

test('durations, tab counts and the header summary stay compact', () => {
    assert.equal(M.duration(42), '42s');
    assert.equal(M.duration(125), '2m');
    assert.equal(M.duration(3 * 3600 + 59), '3h 0m');
    assert.equal(M.duration(2 * 86400 + 5 * 3600), '2d 5h');
    assert.equal(M.duration(-5), '0s');
    const state = {ports:[port(), {...port(5432), database:'PostgreSQL'}],
        containers:[container(), {...container(), id:'b'.repeat(64), name:'db', state:'exited', publishedPorts:[]}],
        images:[{id:'i',tags:['a:b'],used:true,size:'1MB'}], volumes:[]};
    assert.deepEqual(clone(M.counts(state, M.config({}))), {Overview:0, Localhost:2, Docker:2, Images:1, Databases:1, Projects:0, Tools:0});
    assert.equal(M.summary(state, M.config({})), '2 listening · 1 of 2 containers running');
    assert.equal(M.summary(state, M.config({dockerEnabled:false})), '2 listening');
    assert.equal(M.summary({ports:[port()]}, M.config({})), '1 listening');
    assert.deepEqual(clone(M.filters('Localhost').map(f => f.value)), ['all', 'localhost', 'lan']);
    assert.deepEqual(clone(M.filters('Images').map(f => f.value)), ['all', 'images', 'volumes', 'unused']);
});

test('Docker being unreachable is a status with a reason, never a bar error', () => {
    assert.equal(M.barError({ports:'', docker:'docker unavailable', assets:'docker unavailable'}), '');
    assert.equal(M.barError({ports:'ss unavailable'}), 'ss unavailable');
    assert.equal(M.dockerNotice({dockerStatus:'unavailable'}, {docker:'docker unavailable'}, M.config({})),
        'Docker is not reachable: docker unavailable');
    assert.equal(M.dockerNotice({dockerStatus:'available'}, {docker:'Docker resource usage unavailable: timeout'}, M.config({})),
        'Docker resource usage unavailable: timeout');
    assert.equal(M.dockerNotice({}, {}, M.config({dockerEnabled:false})), 'Docker integration is turned off in settings.');
    assert.equal(M.dockerNotice({dockerStatus:'available'}, {}, M.config({})), '');
});

test('an unreachable or disabled Docker clears its inventory instead of showing stale rows', () => {
    const current = {ports:[port()], containers:[container()], images:[{id:'i'}], volumes:[{id:'v'}], dockerStatus:'available'};
    const down = M.absorb(current, {dockerStatus:'unavailable'});
    assert.deepEqual(clone([down.containers, down.images, down.volumes, down.dockerStatus]), [[], [], [], 'unavailable']);
    assert.equal(down.ports, current.ports);
    assert.deepEqual(clone(M.absorb(current, {dockerStatus:'disabled'}).containers), []);
    const up = M.absorb(down, {dockerStatus:'available', containers:[container()]});
    assert.equal(up.containers.length, 1);
    assert.equal(M.absorb(current, {ports:[port()]}).ports, current.ports);
    assert.equal(M.summary(down, M.config({})), '1 listening');
});

test('empty states say why the list is empty', () => {
    assert.match(M.emptyText('Localhost', '', 'all', '', false), /Collecting/);
    assert.equal(M.emptyText('Docker', '', 'all', 'Docker is not reachable: docker unavailable', true),
        'Docker is not reachable: docker unavailable');
    assert.match(M.emptyText('Localhost', 'redis', 'all', '', true), /Nothing matches “redis”/);
    assert.match(M.emptyText('Docker', '', 'running', '', true), /Nothing matches this filter/);
    assert.match(M.emptyText('Localhost', '', 'all', '', true), /Nothing is listening/);
    assert.match(M.emptyText('Databases', '', 'all', '', true), /SQLite/);
    assert.deepEqual(clone(M.tabNames.map(M.tabLabel)), ['Overview', 'Ports', 'Docker', 'Images', 'DBs', 'Projects', 'AI']);
});

test('logs are limited by what Python sends, so astral characters are not rejected', () => {
    const wrap = text => JSON.stringify({schemaVersion:1,kind:'logs',ok:true,errors:[],data:{text,truncated:false}});
    // 32768 code points of emoji are 65536 UTF-16 units.
    assert.equal(M.decode(wrap('😀'.repeat(32768)), 'logs').data.text.length, 65536);
    assert.throws(() => M.decode(wrap('x'.repeat(65537)), 'logs'));
});

test('zoned wildcard binds still open on loopback', () => {
    assert.equal(M.url(port(8080, '0.0.0.0%eth0')), 'http://127.0.0.1:8080/');
    assert.equal(M.url(port(8080, '::%eth0')), 'http://[::1]:8080/');
    assert.equal(M.url(port(8080, 'fe80::1%eth0')), 'http://[fe80::1%25eth0]:8080/');
});

test('a collector that never started says so instead of quoting an exit code', () => {
    assert.match(M.outcome('ports', undefined, -1, false).error, /could not start/);
    assert.match(M.outcome('ports', '', 2, false).error, /exit 2/);
});

test('badge colours come from the theme palette with readable fallbacks', () => {
    const toml = 'accent = "#e74444"\ncolor1 = "#ef5d67"\ncolor2 = "#8edb73"\ncolor3 = \'#f7c553\'\ncolor4 = "#7ca5ff"\n';
    assert.deepEqual(clone(M.palette(toml)), {red:'#ef5d67', green:'#8edb73', yellow:'#f7c553', blue:'#7ca5ff'});
    const fallback = clone(M.palette(''));
    assert.deepEqual(Object.keys(fallback), ['red', 'green', 'yellow', 'blue']);
    assert.ok(Object.values(fallback).every(c => /^#[0-9a-f]{6}$/i.test(c)));
    assert.equal(M.palette('red = "#ff0000"\ncolor1 = "bad"').red, '#ff0000');
    assert.equal(M.palette(undefined).blue, fallback.blue);
});

const project = (p = '/work/project', extra = {}) => ({id:'project:'+p, path:p, name:p.split('/').pop(), root:'/work', branch:'main', detached:false, ahead:1, behind:2, changed:0, untracked:0, conflicts:0, gitState:'clean', ...extra});
const tool = (id = 'claude', available = true) => ({id, name:id, builtin:true, executable:id, path:available?'/bin/'+id:null, available, reason:available?'':'not found', args:[]});
const envelope = (kind, data, extra = {}) => JSON.stringify({schemaVersion:1, kind, ok:true, errors:[], data, ...extra});

test('dashboard identity, fixed tab keys and versioned visibility migration', () => {
    assert.equal(M.pluginId, 'io.github.batuhanmeral.development-dashboard');
    assert.equal(M.legacyPluginId, 'io.github.batuhanmeral.devports');
    assert.equal(M.displayName, 'Development Dashboard');
    assert.deepEqual(clone(M.config({visibleTabs:'Localhost,Docker'}).tabs), ['Overview','Localhost','Docker','Projects','Tools']);
    assert.deepEqual(clone(M.config({settingsVersion:2,visibleTabs:'Docker,Tools'}).tabs), ['Docker','Tools']);
    for (let n=0;n<7;n++) assert.equal(M.tabKey(String(n)), M.tabNames[n]);
    assert.equal(M.tabKey('2', M.config({settingsVersion:2,visibleTabs:'Localhost'})), '');
    assert.equal(M.tabKey('9'), '');
    assert.equal(M.config({}).managementEnabled, false);
    assert.equal(M.config({}).projectDepth, 3);
});

test('dashboard settings validate roots, bounds, editor and custom grammar', () => {
    assert.equal(M.validateSettings({projectRoots:'/work\n/home/u/projects',projectDepth:4,terminal:'kitty',customTools:'Aider | aider | --no-auto-commits'}).length,0);
    for (const invalid of [{projectRoots:'relative'}, {projectRoots:'/proc/x'}, {projectRoots:'/a\0b'}, {projectRoots:Array(17).fill('/x').join('\n')}, {projectDepth:5}, {projectDepth:1.2}, {terminal:'sh'}, {editor:'x'.repeat(257)}, {editor:'code\n--wait'}, {favoriteProjects:'relative'}, {customTools:'bad | sh; rm'}])
        assert.ok(M.validateSettings(invalid).length, JSON.stringify(invalid));
    const cfg = M.config({projectDepth:99,terminal:'invalid',projectRoots:'/work',managementEnabled:true});
    assert.equal(cfg.projectDepth,3); assert.equal(cfg.terminal,'default'); assert.equal(cfg.managementEnabled,true);
    assert.equal(M.parseCustomTools('# ignored\nAider | aider | --token $(id) {path}')[0].args.join(' '), '--token $(id) {path}');
    for (const line of ['Name | ../exec','Name | /a/../exec', 'Name | $(id)', 'Name | exe | '+Array(17).fill('a').join(' '), 'Name | exe | a\0b','Name | exe | a | b'])
        assert.throws(()=>M.parseCustomTools(line),line);
    const old=M.legacySettings({refreshInterval:9, compact:false, evil:'x',managementEnabled:true});
    assert.equal(old.refreshInterval,9); assert.equal(old.compact,false); assert.equal(old.managementEnabled,false); assert.equal(old.evil,undefined);
    assert.equal(M.legacySettings({refreshInterval:'9'}).refreshInterval,5);
});

test('decode isolates new scopes and rejects forged project and tool identities', () => {
    assert.equal(M.decode(envelope('projects',{projects:[project()],skipped:2}), 'projects').data.skipped,2);
    assert.equal(M.decode(envelope('tools',{tools:[tool()]}),'tools').data.tools.length,1);
    assert.equal(M.decode(envelope('legacy',{legacy:{found:true,installed:false,settings:{compact:false}}}),'legacy').data.legacy.found,true);
    for (const p of [project('relative'),project('/a',{id:'project:/b'}), project('/a\nb')])
        assert.throws(()=>M.decode(envelope('projects',{projects:[p]}),'projects'));
    assert.throws(()=>M.decode(envelope('tools',{tools:[tool('$(id)')]}),'tools'));
    assert.throws(()=>M.decode(envelope('projects',{ports:[port()]}),'projects'));
    assert.throws(()=>M.decode(envelope('ports',{projects:[project()]}),'ports'));
    assert.throws(()=>M.decode(envelope('projects',{projects:[project(),project()]}),'projects'));
    assert.equal(M.decodeAction(envelope('action',{state:'running'},{action:'docker-start'})).action,'docker-start');
    for (const raw of [envelope('ports',{}), envelope('action',[],{action:'x'}), envelope('action',{}, {action:2})]) assert.throws(()=>M.decodeAction(raw));
    const next=M.merge({}, {projects:[project()],tools:[tool()],legacy:{found:false},skipped:1});
    assert.equal(next.projects.length,1); assert.equal(next.tools.length,1); assert.equal(next.skipped,1);
});

test('project services associate longest path only and respect path boundaries', () => {
    const state={projects:[project('/a/b'),project('/a/b/nested'),project('/a/bc')],ports:[{...port(),cwd:'/a/b/nested/src'},{...port(4000),cwd:'/a/bc/src'}],containers:[{...container(),publishedPorts:[],composeDir:'/a/b/docker'}]};
    const cfg=M.config({});
    const ports=M.rows(state,'Localhost','','all',cfg);
    assert.equal(ports[0].projectPath,'/a/b/nested'); assert.equal(ports[1].projectPath,'/a/bc');
    const svc=M.projectServices(state,'/a/b',cfg);
    assert.equal(svc.length,1); assert.equal(svc[0].kind,'container');
    assert.equal(M.projectServices(state,'/a/b/nested',cfg).length,1);
    assert.equal(M.projectServices(state,'/a',cfg).length,0);
});

test('project and tool rows filter, search and put favorites first', () => {
    const state={projects:[project('/work/a'),project('/work/z',{gitState:'dirty',changed:2}),project('/work/b',{branch:'feature'})],tools:[tool(),tool('codex',false)],ports:[port()]};
    const cfg=M.config({favoriteProjects:'/work/z'});
    assert.equal(M.rows(state,'Projects','','all',cfg)[0].title,'z');
    assert.equal(M.rows(state,'Projects','','favorites',cfg).length,1);
    assert.equal(M.rows(state,'Projects','','dirty',cfg)[0].badge,'main*');
    assert.equal(M.rows(state,'Projects','feature','all',cfg)[0].title,'b');
    assert.equal(M.rows(state,'Tools','','available',cfg).length,1);
    assert.equal(M.rows(state,'Tools','codex','all',cfg)[0].badge,'missing');
    assert.equal(M.toggleFavorite(cfg,'/work/z'),'');
    assert.equal(M.toggleFavorite(cfg,'/work/a'),'/work/z\n/work/a');
    assert.match(M.emptyText('Projects','','all','',false,M.config({})),/No project folders yet/);
    assert.match(M.emptyText('Projects','','all','',false,M.config({projectRoots:'/work'})),/Scanning projects/);
});

test('overview counts inventory and limits favorite and exposed lists', () => {
    const state={projects:[project()],tools:[tool(),tool('codex',false)],ports:[port(),{...port(5432,'0.0.0.0'),database:'PostgreSQL'}],containers:[{...container(),publishedPorts:[],health:'unhealthy'}]};
    const cfg=M.config({favoriteProjects:'/work/project'});
    const o=M.overview(state,cfg);
    assert.equal(o.listening.total,2);assert.equal(o.listening.exposed,1);
    assert.deepEqual(clone(o.containers),{running:1,total:1,unhealthy:1});
    assert.equal(o.databases,1);assert.equal(o.projects.total,1);assert.equal(o.projects.favorites,1);
    assert.deepEqual(clone(o.aiTools),{available:1,total:2});
    assert.equal(o.favorites[0].serviceCount,2);assert.equal(o.exposed.length,1);
    assert.equal(M.overview({...state,ports:Array.from({length:8},(_,i)=>port(8000+i,'0.0.0.0'))},cfg).exposed.length,5);
    const facts=M.facts(M.rows(state,'Projects','','all',cfg)[0],0);
    assert.match(facts.find(f=>f.label==='Branch').value,/1.*2/);
    assert.equal(facts.find(f=>f.label==='Services').value,'2');
});

test('management is opt in and never terminates container or unowned listeners', () => {
    const cfg=M.config({managementEnabled:true});
    const c=M.viewRow(container(),'container');
    assert.deepEqual(clone(M.availableActions(c,M.config({}),{}).map(a=>a.id)),['logs','open']);
    for (const id of ['stop','restart']) assert.ok(M.availableActions(c,cfg,{}).find(a=>a.id===id).confirm);
    assert.ok(M.availableActions(M.viewRow({...container(),state:'exited'},'container'),cfg,{}).some(a=>a.id==='start'));
    const p=M.viewRow({...port(),ownedByUser:true,startTicks:'123'},'port');
    assert.equal(M.canManage(p,cfg),true); assert.equal(M.canManage(p,M.config({})),false);
    for (const extra of [{ownedByUser:false},{containerName:'web'},{containerIds:[cid]},{pid:null},{startTicks:null}])
        assert.equal(M.canManage(M.viewRow({...port(),ownedByUser:true,startTicks:'123',...extra},'port'),cfg),false);
    assert.ok(M.availableActions(M.viewRow(project(),'project'),cfg,{}).some(a=>a.key==='F'));
});

test('actions use separate validated argv entries for every operation', () => {
    const cfg=M.config({projectRoots:'/work\n/home/me',terminal:'kitty',editor:'code --wait',customTools:'Test | tool | $(id)'});
    for(const op of ['start','stop','restart']) assert.deepEqual(clone(M.actionArgs(op,container(),cfg,{})),['docker-'+op,'--container-id='+cid]);
    assert.equal(M.actionArgs('stop',{id:';rm'},cfg,{}),null);
    assert.deepEqual(clone(M.actionArgs('terminate',{...port(),ownedByUser:true,startTicks:'123'},cfg,{})),['process-terminate','--pid=100','--start-ticks=123','--port=3000']);
    for(const p of [{...port(),pid:1,startTicks:'1'}, {...port(),startTicks:'x'}]) assert.equal(M.actionArgs('terminate',p,cfg,{}),null);
    const base=['--path=/work/project','--project-root=/work','--project-root=/home/me'];
    assert.deepEqual(clone(M.actionArgs('terminal',project(),cfg,{})),['open-terminal',...base,'--terminal=kitty']);
    assert.deepEqual(clone(M.actionArgs('editor',project(),cfg,{})),['open-editor',...base,'--editor=code --wait']);
    assert.deepEqual(clone(M.actionArgs('files',project(),cfg,{})),['open-files',...base]);
    assert.deepEqual(clone(M.actionArgs('launch-tool',tool(),cfg,{path:'/work/project'})),['launch-tool',...base,'--tool=claude','--terminal=kitty','--custom-tool=Test | tool | $(id)']);
    for(const p of ['relative','/work/../outside','/work/a\nfoo']) assert.equal(M.actionArgs('terminal',project(p),cfg,{}),null,p);
    const weird='/work/$(id);name';
    assert.equal(M.actionArgs('terminal',project(weird),cfg,{})[1],'--path='+weird);
    assert.equal(M.actionArgs('evil',project(),cfg,{}),null);
});

test('confirmation strings preserve names as plain data and explain SIGTERM', () => {
    assert.equal(M.confirmText('stop',M.viewRow(container(),'container')),'Stop container “web”?');
    assert.equal(M.confirmText('restart',M.viewRow(container(),'container')),'Restart container “web”?');
    assert.match(M.confirmText('terminate',M.viewRow({...port(5173),pid:4242},'port')),/Send SIGTERM to vite \(PID 4242\) on port 5173\? It will not be force-killed\./);
    assert.equal(M.confirmText('stop',M.viewRow({...container(),name:'<img src=x>'},'container')),'Stop container “<img src=x>”?');
});

test('open dashboard schedules new scopes and legacy is only collected once', () => {
    const cfg=M.config({projectRoots:'/work'});
    const last={ports:10000,docker:10000,assets:10000};
    assert.equal(M.nextScope(10000,true,cfg,last,false),'projects');last.projects=10000;
    assert.equal(M.nextScope(10000,true,cfg,last,false),'tools');last.tools=10000;
    assert.equal(M.nextScope(10000,true,cfg,last,false),'legacy');last.legacy=10000;
    assert.equal(M.nextScope(10000,true,cfg,last,false),'');
    assert.equal(M.nextScope(10000,false,cfg,{},false),'ports');
    assert.equal(M.nextScope(4000000,true,M.config({dockerEnabled:false}),{ports:4000000,tools:4000000,legacy:1},false),'');
});

test('project paths reject invalid UTF-16 and accept the longest contract path', () => {
    const long='/'+ 'a'.repeat(4095);
    assert.equal(M.decode(envelope('projects',{projects:[project(long)]}),'projects').data.projects[0].path,long);
    assert.equal(M.actionArgs('terminal',project('/work/\ud800'),M.config({projectRoots:'/work'}),{}),null);
});

test('process start ticks retain their string identity at the frontend boundary', () => {
    const cfg=M.config({managementEnabled:true});
    const numeric={...port(),ownedByUser:true,startTicks:123};
    assert.equal(M.canManage(M.viewRow(numeric,'port'),cfg),false);
    assert.equal(M.actionArgs('terminate',numeric,cfg,{}),null);
});


test('canonical project paths under symlink roots are authorized by the backend', () => {
    const cfg=M.config({projectRoots:'/home/u/projects-link'});
    for (const op of ['terminal','editor','files']) {
        const args=M.actionArgs(op,project('/mnt/projects/app'),cfg,{});
        assert.ok(args,op);
        assert.ok(args.includes('--path=/mnt/projects/app'));
        assert.ok(args.includes('--project-root=/home/u/projects-link'));
    }
    assert.ok(M.actionArgs('launch-tool',tool(),cfg,{path:'/mnt/projects/app'}));
    assert.ok(M.actionArgs('terminal',project('/work2/app'),cfg,{}));
    assert.equal(M.actionArgs('terminal',project('/mnt/projects/app'),{...cfg,projectRoots:'/proc'},{}),null);
});

test('option-shaped tool definitions and editor values stay attached to their option', () => {
    const cfg=M.config({projectRoots:'/work',editor:'-foo',customTools:'-x|aider'});
    const edit=M.actionArgs('editor',project(),cfg,{});
    assert.ok(edit.includes('--editor=-foo'));
    assert.ok(M.actionArgs('launch-tool',tool(),cfg,{path:'/work/project'}).includes('--custom-tool=-x|aider'));
});

test('512 projects and 60 listeners keep counts and project rows below 300ms', () => {
    const state={projects:Array.from({length:512},(_,i)=>project('/work/project-'+i)),ports:Array.from({length:60},(_,i)=>({...port(8000+i),cwd:'/work/project-'+i+'/src'}))};
    const cfg=M.config({projectRoots:'/work'});
    const before=performance.now();
    const counts=M.counts(state,cfg);
    const projects=M.rows(state,'Projects','','all',cfg);
    const elapsed=performance.now()-before;
    console.log('dashboard 512/60 counts + project rows: '+elapsed.toFixed(2)+' ms');
    assert.equal(counts.Projects,512);
    assert.equal(counts.Localhost,60);
    assert.equal(projects.filter(p=>p.serviceCount===1).length,60);
    assert.ok(elapsed<300,'counts + projects took '+elapsed.toFixed(2)+' ms');
});

test('service indexing remains current across inventory and view-setting changes', () => {
    const state={projects:[project('/work/project'),project('/work/project/nested')],ports:[port(),{...port(4000),cwd:'/work/project/nested/src'}],containers:[{...container(),publishedPorts:[],composeDir:'/work/project/docker'}]};
    const cfg=M.config({});
    assert.equal(M.projectServices(state,'/work/project',cfg).length,2);
    assert.equal(M.rows(state,'Projects','','active',cfg).length,2);
    assert.equal(M.projectServices(state,'/work/project',M.config({hiddenPorts:'3000',dockerEnabled:false})).length,0);
    assert.equal(M.projectServices({...state,ports:[]},'/work/project',cfg).length,1);
    assert.equal(M.rows({...state,ports:[]},'Projects','','active',cfg).length,1);
    const o=M.overview(state,cfg);
    assert.equal(o.listening.total,2);
});

test('scope diagnostics replace scanning placeholders even without an accepted inventory', () => {
    const cfg=M.config({projectRoots:'/work'});
    for (const tab of ['Projects','Tools']) {
        assert.equal(M.emptyText(tab,'','all','Collector timed out.',false,cfg),'Collector timed out.');
        assert.equal(M.emptyText(tab,'needle','active','Partial inventory failure.',true,cfg),'Partial inventory failure.');
    }
});

test('direct project views preserve the optional configuration argument with indexed services', () => {
    const state={projects:[project()],ports:[port()]};
    assert.equal(M.viewRow(state.projects[0],'project',state).serviceCount,1);
});
