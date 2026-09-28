// Exercises the production TypeScript core with an in-memory HTTP boundary.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const clt = process.env.DEVECO_CLI_CLT_PATH;
if (!clt) throw new Error('Set DEVECO_CLI_CLT_PATH before running tests.');
const ts = require(path.join(clt, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const out = fs.mkdtempSync(path.join(os.tmpdir(), 'qbitharmony-test-'));
process.on('exit', () => fs.rmSync(out, { recursive: true, force: true }));
for (const name of ['Models', 'Format', 'SyncState', 'ServerSelection', 'QbitClient', 'FileTree', 'CompletionNotice']) {
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/core', name + '.ts'), 'utf8');
  fs.writeFileSync(path.join(out, name + '.js'), ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText);
}
const { QbitClient, normalizeBaseUrl, formEncode, extractSid } = require(path.join(out, 'QbitClient.js'));
const { selectTorrents, bytes, percent, duration, stateLabel } = require(path.join(out, 'Format.js'));
const { SyncState } = require(path.join(out, 'SyncState.js'));
const { initialServer, upsertServer, serverAfterRemoval } = require(path.join(out, 'ServerSelection.js'));
const profile = { id: 'test', name: 'NAS', url: 'https://nas.example/qbt/', username: '名字&x', remember: false };
const hash = 'a'.repeat(40);
const { completionNotice, emptyNotice, NOTICE_MAX_AGE } = require(path.join(out, 'CompletionNotice.js'));
const noticeNow = 1800000000000;
const noticeTorrent = (id, complete, stamp = noticeNow / 1000) => ({
  hash: id.toString(16).padStart(40, '0'), name: 'task-' + id, state: complete ? 'stalledUP' : 'downloading',
  progress: complete ? 1 : .4, added_on: noticeNow / 1000 - 100, completion_on: complete ? stamp : -1
});
const noticeBaseline = () => completionNotice(emptyNotice(), [noticeTorrent(1, false), noticeTorrent(2, false)], noticeNow, noticeNow).state;
test('local notifications: first run and gaps over one day silently establish baseline', () => {
  const many = Array.from({ length: 2000 }, (_, i) => noticeTorrent(i, true));
  assert.equal(completionNotice(emptyNotice(), many, noticeNow, noticeNow).events.length, 0);
  const late = noticeNow + NOTICE_MAX_AGE + 1;
  assert.equal(completionNotice(noticeBaseline(), many, late, late).events.length, 0);
});
test('local notifications: one summary for a batch, no repeat after persisted restart', () => {
  const list = [noticeTorrent(1, true), noticeTorrent(2, true)];
  const result = completionNotice(noticeBaseline(), list, noticeNow + 1000, noticeNow + 1000);
  assert.equal(result.events.length, 2);
  const resumed = JSON.parse(JSON.stringify(result.state));
  assert.equal(completionNotice(resumed, list, noticeNow + 100000, noticeNow + 100000).events.length, 0);
});
test('local notifications: two-hour background interval still reports fresh completions', () => {
  const time = noticeNow + 7200000;
  const result = completionNotice(noticeBaseline(), [noticeTorrent(1, true, (noticeNow + 60000) / 1000)], time, time);
  assert.equal(result.events.length, 1);
});
test('local notifications: stale and undated completion events are not replayed', () => {
  for (const stamp of [-1, 0, (noticeNow - NOTICE_MAX_AGE - 1000) / 1000]) {
    assert.equal(completionNotice(noticeBaseline(), [noticeTorrent(1, true, stamp)], noticeNow + 1000, noticeNow + 1000).events.length, 0);
  }
});
test('local notifications: unknown historic imports stay silent, newly added completions count', () => {
  assert.equal(completionNotice(noticeBaseline(), [noticeTorrent(3, true)], noticeNow + 1000, noticeNow + 1000).events.length, 0);
  const t = { ...noticeTorrent(3, true), added_on: noticeNow / 1000 };
  assert.equal(completionNotice(noticeBaseline(), [t], noticeNow + 1000, noticeNow + 1000).events.length, 1);
});
test('local notifications: late cross-process snapshots do not undo newer state', () => {
  const r = completionNotice(noticeBaseline(), [noticeTorrent(1, true)], noticeNow + 5000, noticeNow + 5000);
  const late = completionNotice(r.state, [noticeTorrent(1, false)], noticeNow + 1000, noticeNow + 6000);
  assert.deepEqual(late.state, r.state); assert.equal(late.events.length, 0);
});
test('local notifications: recheck is not a second completion and burst updates are throttled', () => {
  let r = completionNotice(noticeBaseline(), [noticeTorrent(1, true), noticeTorrent(2, false)], noticeNow + 1000, noticeNow + 1000);
  r = completionNotice(r.state, [noticeTorrent(1, false), noticeTorrent(2, true)], noticeNow + 5000, noticeNow + 5000);
  assert.equal(r.events.length, 0); assert.equal(r.state.pending.length, 1);
  r = completionNotice(r.state, [noticeTorrent(1, true), noticeTorrent(2, true)], noticeNow + 62000, noticeNow + 62000);
  assert.equal(r.events.length, 1); assert.equal(r.events[0].hash, noticeTorrent(2, true).hash);
});
test('local notifications: clock rollback rebases silently', () => {
  assert.equal(completionNotice(noticeBaseline(), [noticeTorrent(1, true)], noticeNow - 1000, noticeNow - 1000).events.length, 0);
});
const ok = (body = '', cookies = '') => ({ status: 200, body, cookies });
class FakeTransport {
  requests = [];
  constructor(responses) { this.responses = [...responses]; }
  async send(request) {
    this.requests.push(request);
    if (!this.responses.length) throw new Error('Unexpected request: ' + request.url);
    const result = this.responses.shift();
    if (result instanceof Error) throw result;
    return result;
  }
}
async function connected(version, responses = []) {
  const transport = new FakeTransport([ok('Ok.', 'SID=secret; HttpOnly; Path=/'), ok(version), ...responses]);
  const client = new QbitClient(profile, 'p&= 汉字', transport);
  await client.connect();
  return { client, transport };
}
test('base URL preserves reverse-proxy subpaths and rejects unsafe/ambiguous input', () => {
  assert.equal(normalizeBaseUrl(' https://host:8080/qbt/// '), 'https://host:8080/qbt');
  assert.equal(normalizeBaseUrl('http://[::1]:8080'), 'http://[::1]:8080');
  for (const value of ['ftp://host', 'host:8080', 'https://a@host', 'https://host?q=x', 'https://host#x', 'http://host/api/v2']) {
    assert.throws(() => normalizeBaseUrl(value));
  }
});
test('login encodes credentials, scopes SID and sends matching Referer', async () => {
  const { transport } = await connected('v5.0.4');
  assert.equal(transport.requests[0].url, 'https://nas.example/qbt/api/v2/auth/login');
  assert.equal(transport.requests[0].headers.Referer, 'https://nas.example/qbt/');
  const body = new URLSearchParams(transport.requests[0].body);
  assert.equal(body.get('username'), profile.username);
  assert.equal(body.get('password'), 'p&= 汉字');
  assert.equal(transport.requests[1].headers.Cookie, 'SID=secret');
});
test('failed login and IP bans never proceed to operations', async () => {
  for (const response of [ok('Fails.'), { status: 403, body: '', cookies: '' }]) {
    const t = new FakeTransport([response]);
    await assert.rejects(new QbitClient(profile, 'bad', t).connect());
    assert.equal(t.requests.length, 1);
  }
});
test('cookie parsing supports Set-Cookie headers and NetworkKit Netscape jars', () => {
  assert.equal(extractSid('SID=abc; Path=/; HttpOnly'), 'SID=abc');
  assert.equal(extractSid('#HttpOnly_localhost\tFALSE\t/\tFALSE\t0\tSID\tabc'), 'SID=abc');
  assert.equal(extractSid(''), '');
});
test('rejects proxy HTML masquerading as version response', async () => {
  const t = new FakeTransport([ok('Ok.'), ok('<html>login</html>')]);
  await assert.rejects(new QbitClient(profile, '', t).connect(), /版本/);
});
test('qBittorrent 4 uses pause/resume; 5 uses stop/start', async () => {
  for (const [version, pause, resume] of [['v4.6.7', 'pause', 'resume'], ['v5.1.2', 'stop', 'start']]) {
    const { client, transport } = await connected(version, [ok(), ok()]);
    await client.action('stop', [hash]); await client.action('start', [hash]);
    assert.ok(transport.requests[2].url.endsWith('/torrents/' + pause));
    assert.ok(transport.requests[3].url.endsWith('/torrents/' + resume));
    assert.equal(transport.requests[2].method, 'POST');
    assert.equal(new URLSearchParams(transport.requests[2].body).get('hashes'), hash);
  }
});
test('authorization rejection retries once with new SID', async () => {
  const { client, transport } = await connected('v5.1.2', [
    { status: 403, body: '', cookies: '' }, ok('Ok.', 'SID=fresh; Path=/'), ok('[]')
  ]);
  assert.deepEqual(await client.torrents(), []);
  assert.equal(transport.requests[4].headers.Cookie, 'SID=fresh');
});
test('persistent 403 fails after one login; no retry loop', async () => {
  const forbidden = { status: 403, body: '', cookies: '' };
  const { client, transport } = await connected('v5.1.2', [forbidden, ok('Ok.'), forbidden]);
  await assert.rejects(client.torrents(), /HTTP 403/);
  assert.equal(transport.requests.length, 5);
});
test('timeout on mutation is not replayed', async () => {
  const { client, transport } = await connected('v5.1.2', [new Error('timeout')]);
  await assert.rejects(client.action('stop', [hash]), /timeout/);
  assert.equal(transport.requests.length, 3);
});
test('SID is isolated per client', async () => {
  const a = await connected('v5.1.2');
  const t = new FakeTransport([ok('Ok.', 'SID=other; Path=/'), ok('v5.1.2')]);
  await new QbitClient({ ...profile, url: 'https://other.example' }, '', t).connect();
  assert.equal(t.requests[0].headers.Cookie, '');
  assert.equal(t.requests[1].headers.Cookie, 'SID=other');
  assert.equal(a.transport.requests[1].headers.Cookie, 'SID=secret');
});
test('deletion explicitly preserves files unless selected otherwise', async () => {
  const { client, transport } = await connected('v5.0.4', [ok(), ok()]);
  await client.remove(hash, false); await client.remove(hash, true);
  assert.equal(new URLSearchParams(transport.requests[2].body).get('deleteFiles'), 'false');
  assert.equal(new URLSearchParams(transport.requests[3].body).get('deleteFiles'), 'true');
});
test('adding links sends version-specific stopped flag and multipart fields', async () => {
  for (const [version, flag] of [['v4.6.7', 'paused'], ['v5.1.2', 'stopped']]) {
    const { client, transport } = await connected(version, [ok('Ok.')]);
    await client.add('magnet:?xt=urn:btih:abc\nhttps://example.org/a.torrent', '/下载', 'Linux', true);
    const fields = Object.fromEntries(transport.requests[2].fields.map(f => [f.name, f.value]));
    assert.equal(fields[flag], 'true'); assert.equal(fields.savepath, '/下载');
    assert.equal(fields.urls.split('\n').length, 2);
  }
});
test('torrent upload preserves bytes and does not send competing urls', async () => {
  const { client, transport } = await connected('v5.1.2', [ok('Ok.')]);
  const upload = { name: 'test.torrent', data: new Uint8Array([0, 255, 100]).buffer };
  await client.add('', '', '', false, upload);
  assert.equal(transport.requests[2].upload, upload);
  assert.equal(transport.requests[2].fields.some(f => f.name === 'urls'), false);
});
test('failed additions and invalid inputs surface errors', async () => {
  const { client } = await connected('v5.1.2', [ok('Fails.')]);
  await assert.rejects(client.add('magnet:?xt=x', '', '', false), /未接受/);
  await assert.rejects(client.add('javascript:alert(1)', '', '', false));
  await assert.rejects(client.action('stop', []));
  await assert.rejects(client.action('stop', ['all']));
});
test('limits use bytes per second; invalid values do not mutate', async () => {
  const { client, transport } = await connected('v5.1.2', [ok(), ok()]);
  for (const value of ['-1', '1.5', '', 'NaN', '10000001']) await assert.rejects(client.setLimit('Download', value));
  await client.setLimit('Download', '512'); await client.setLimit('Upload', '0');
  assert.equal(transport.requests[2].body, 'limit=524288');
  assert.equal(transport.requests[3].body, 'limit=0');
});
test('query parameters and non-ASCII values are percent encoded', () => {
  assert.equal(new URLSearchParams(formEncode([{ name: 'category', value: '电影 & TV' }])).get('category'), '电影 & TV');
});
test('filter/sort is immutable, supports stopped states and exact tags', () => {
  const torrents = [
    { hash: '1', name: 'Ubuntu', state: 'downloading', progress: .3, category: 'Linux', tags: 'iso, official', added_on: 1 },
    { hash: '2', name: 'Debian', state: 'stoppedUP', progress: 1, category: 'Linux', tags: 'iso', added_on: 3 },
    { hash: '3', name: 'Fedora', state: 'uploading', progress: 1, category: 'Linux', tags: 'isotope', added_on: 2 }
  ];
  assert.deepEqual(selectTorrents(torrents, '', 3, 0).map(t => t.hash), ['2']);
  assert.deepEqual(selectTorrents(torrents, '', 0, 0, 'Linux', 'iso').map(t => t.hash), ['1', '2']);
  assert.deepEqual(selectTorrents(torrents, 'UBU', 1, 0).map(t => t.hash), ['1']);
  assert.deepEqual(selectTorrents(torrents, '', 2, 0).map(t => t.hash), ['3']);
  assert.equal(torrents[0].hash, '1');
});
test('formatting handles empty, infinite and boundary values', () => {
  assert.equal(bytes(1024), '1.0 KiB'); assert.equal(bytes(-1), '0 B');
  assert.equal(percent(1.5), 100); assert.equal(percent(NaN), 0);
  assert.equal(duration(8640000), '—'); assert.equal(stateLabel('pausedDL'), '已暂停');
  assert.equal(stateLabel('stoppedUP'), '已暂停');
});
test('startup restores last server, falling back only if missing or preference disabled', () => {
  const a = { ...profile, id: 'a' }, b = { ...profile, id: 'b' };
  assert.equal(initialServer([a,b], 'b', true), b);
  assert.equal(initialServer([a,b], 'missing', true), a);
  assert.equal(initialServer([a,b], 'b', false), a);
  assert.equal(initialServer([], 'b', true), undefined);
});
test('editing preserves server order; removal preserves or replaces active selection', () => {
  const a = { ...profile, id: 'a' }, b = { ...profile, id: 'b' };
  const changed = { ...a, name: 'Edited' };
  assert.deepEqual(upsertServer([a,b], changed).map(s=>s.id), ['a','b']);
  assert.equal(upsertServer([a,b], changed)[0].name, 'Edited');
  assert.equal(serverAfterRemoval([a,b], 'a', 'a'), b);
  assert.equal(serverAfterRemoval([a,b], 'a', 'b'), b);
  assert.equal(serverAfterRemoval([a], 'a', 'a'), undefined);
});
test('incremental sync retains omitted fields and applies torrent/category/tag removals', () => {
  const state = new SyncState();
  state.merge({ rid: 1, full_update: true, torrents: { [hash]: { name: 'Linux', progress: .1, category: 'ISO' } },
    server_state: { dl_info_speed: 100 }, categories: { ISO: { name: 'ISO', savePath: '/iso' } }, tags: ['old'],
    trackers: { 'tracker.example': [hash] } });
  const update = state.merge({ rid: 2, torrents: { [hash]: { progress: .5 } }, tags: ['new'], tags_removed: ['old'] });
  assert.equal(update.torrents[0].name, 'Linux'); assert.equal(update.torrents[0].hash, hash);
  assert.equal(update.torrents[0].progress, .5); assert.equal(update.transfer.dl_info_speed, 100);
  assert.deepEqual(update.tags, ['new']);
  const removed = state.merge({ rid: 3, torrents_removed: [hash], categories_removed: ['ISO'], trackers_removed: ['tracker.example'] });
  assert.equal(removed.torrents.length, 0); assert.equal(removed.categories.length, 0); assert.deepEqual(removed.trackers, {});
});
test('incremental sync ignores stale rid but accepts full server reset', () => {
  const state = new SyncState();
  state.merge({ rid: 10, full_update: true, torrents: { [hash]: { name: 'Linux' } } });
  assert.equal(state.merge({ rid: 9, torrents_removed: [hash] }).torrents.length, 1);
  assert.equal(state.merge({ rid: 1, full_update: true }).torrents.length, 0);
  assert.throws(() => state.merge({}), /格式/);
});
test('sync requests pass previous revision for sparse server responses', async () => {
  const { client, transport } = await connected('v5.1.2', [ok(JSON.stringify({ rid: 7, full_update: true })), ok(JSON.stringify({ rid: 8 }))]);
  await client.sync(); await client.sync();
  assert.ok(transport.requests[2].url.endsWith('sync/maindata?rid=0'));
  assert.ok(transport.requests[3].url.endsWith('sync/maindata?rid=7'));
});
test('upstream search terms include AND and minus exclusion; paused downloads are downloadable state', () => {
  const data = [{ hash, name: 'Ubuntu Desktop arm64', state: 'stoppedDL', category: 'Linux/Ubuntu', tags: '', dlspeed: 0, upspeed: 0 }];
  assert.equal(selectTorrents(data, 'ubuntu desktop -amd64', 1, 1).length, 1);
  assert.equal(selectTorrents(data, 'ubuntu -arm64', 1, 1).length, 0);
  assert.equal(selectTorrents(data, '', 8, 1, 'Linux', '', false, true).length, 1);
  assert.equal(selectTorrents(data, '', 8, 1, 'Linux').length, 0);
  assert.equal(selectTorrents(data, '', 8, 1, '', '\u0000').length, 1);
});
test('common add options preserve server defaults and encode speeds correctly', async () => {
  const { client, transport } = await connected('v5.1.2', [ok('Ok.')]);
  await client.add('magnet:?xt=x', '', '', false, undefined, { tags: 'iso,linux', rename: 'custom', sequential: true,
    firstLast: true, autoTmm: 0, downloadLimit: '256', uploadLimit: '' });
  const fields = Object.fromEntries(transport.requests[2].fields.map(f=>[f.name,f.value]));
  assert.equal(fields.dlLimit, '262144'); assert.equal(fields.tags, 'iso,linux'); assert.equal(fields.rename, 'custom');
  assert.equal(fields.sequentialDownload, 'true'); assert.equal(fields.firstLastPiecePrio, 'true');
  assert.equal(fields.autoTMM, undefined); assert.equal(fields.upLimit, undefined);
});
test('batch actions only target explicit hashes', async () => {
  const { client, transport } = await connected('v5.1.2', [ok(), ok()]);
  const hashes = [hash, 'b'.repeat(40)];
  await client.action('stop', hashes); await client.removeMany(hashes, false);
  assert.equal(new URLSearchParams(transport.requests[2].body).get('hashes'), hashes.join('|'));
  assert.equal(new URLSearchParams(transport.requests[3].body).get('deleteFiles'), 'false');
  await assert.rejects(client.removeMany(['all'], true));
});
test('sorting follows upstream direction and keeps unknown ETA and queue priority last', () => {
  const items = [{ hash: 'a', name: 'A', state: 'downloading', category: '', tags: '', added_on: 1, eta: 8640000, priority: 0, last_activity: 10 },
    { hash: 'b', name: 'B', state: 'downloading', category: '', tags: '', added_on: 2, eta: 60, priority: 1, last_activity: 20 }];
  assert.deepEqual(selectTorrents(items, '', 0, 0).map(t => t.hash), ['a', 'b']);
  for (const sort of [7, 8, 16]) assert.deepEqual(selectTorrents(items, '', 0, sort).map(t => t.hash), ['b', 'a']);
  assert.deepEqual(selectTorrents(items, '', 0, 0, '', '', true).map(t => t.hash), ['b', 'a']);
});
test('automatic torrent management does not override category save path', async () => {
  const { client, transport } = await connected('v5.1.2', [ok('Ok.')]);
  await client.add('magnet:?xt=x', '/manual', 'Linux', false, undefined,
    { tags: '', rename: '', sequential: false, firstLast: false, autoTmm: 2, downloadLimit: '', uploadLimit: '' });
  const fields = Object.fromEntries(transport.requests[2].fields.map(f => [f.name, f.value]));
  assert.equal(fields.autoTMM, 'true'); assert.equal(fields.savepath, undefined);
});

test('detail endpoints preserve timestamps, peer addresses and replace disconnected peers', async () => {
  const peer = { ip: '2001:db8::1', port: 6881, dl_speed: 1024, up_speed: 2048, downloaded: 123, uploaded: 456, progress: .5, client: 'test', connection: 'uTP', flags: 'D' };
  const { client, transport } = await connected('v5.1.2', [ok(JSON.stringify({ addition_date: 1790409600, completion_date: -1 })), ok(JSON.stringify({ full_update: true, peers: { one: peer } })), ok(JSON.stringify({ full_update: true, peers: {} }))]);
  assert.equal((await client.properties(hash)).addition_date, 1790409600);
  assert.deepEqual(await client.peers(hash), [peer]);
  assert.deepEqual(await client.peers(hash), []);
  assert.match(transport.requests[2].url, /torrents\/properties\?hash=/);
  for (const req of transport.requests.slice(3)) {
    assert.match(req.url, /sync\/torrentPeers\?hash=.*&rid=0$/);
    assert.equal(req.method, 'GET');
  }
});

const { fileTree, toggleFileSelection, sharedLinks } = require(path.join(out, 'FileTree.js'));
test('file tree aggregates weighted progress, nested folders and noncontiguous server indexes', () => {
  const files = [
    { index: 7, name: 'foo/a.bin', size: 100, progress: 1, priority: 1 },
    { index: 12, name: 'foo/sub/b.bin', size: 300, progress: 0, priority: 0 },
    { index: 99, name: 'foobar/c.bin', size: 1, progress: 1, priority: 1 }
  ];
  const roots = fileTree(files, []);
  assert.deepEqual(roots.map(x => x.path), ['foo', 'foobar']);
  assert.deepEqual(roots[0].ids, [7, 12]);
  assert.equal(roots[0].progress, .25);
  assert.equal(roots[0].priority, -1);
  assert.deepEqual(fileTree(files, ['foo']).map(x => x.path), ['foo', 'foo/sub', 'foo/a.bin', 'foobar']);
  assert.ok(fileTree(files, ['foo', 'foo/sub']).some(x => x.path === 'foo/sub/b.bin'));
  assert.deepEqual(toggleFileSelection([7, 99], [7, 12]), [7, 99, 12]);
  assert.deepEqual(toggleFileSelection([7, 12, 99], [7, 12]), [99]);
});
test('share text extracts and deduplicates links without evaluating surrounding text', () => {
  assert.equal(sharedLinks('下载 magnet:?xt=urn:btih:123&dn=Test\nmagnet:?xt=urn:btih:123&dn=Test https://example.com/a.torrent'),
    'magnet:?xt=urn:btih:123&dn=Test\nhttps://example.com/a.torrent');
  assert.equal(sharedLinks('file:///private/a.torrent javascript:alert(1)'), '');
});
test('batch file priority uses real server ids and rejects invalid selection', async () => {
  const { client, transport } = await connected('v5.0.4', [ok()]);
  await client.setFilePriorities(hash, [7, 12], 6);
  assert.equal(new URLSearchParams(transport.requests.at(-1).body).get('id'), '7|12');
  await assert.rejects(client.setFilePriorities(hash, [], 6));
  await assert.rejects(client.setFilePriorities(hash, [-1], 6));
  await assert.rejects(client.setFilePriorities(hash, [7], 5));
});
test('task speed and seeding limits preserve qBittorrent sentinel values and minutes', async () => {
  const { client, transport } = await connected('v5.0.4', [ok(), ok()]);
  await client.setTorrentLimit(hash, 'Upload', '128');
  assert.equal(new URLSearchParams(transport.requests.at(-1).body).get('limit'), '131072');
  assert.ok(transport.requests.at(-1).url.endsWith('/torrents/setUploadLimit'));
  await client.setShareLimits(hash, '1.5', '-2', '-1');
  const body = new URLSearchParams(transport.requests.at(-1).body);
  assert.equal(body.get('ratioLimit'), '1.5');
  assert.equal(body.get('seedingTimeLimit'), '-2');
  assert.equal(body.get('inactiveSeedingTimeLimit'), '-1');
  await assert.rejects(client.setShareLimits(hash, 'NaN', '5', '2'));
  await assert.rejects(client.setShareLimits(hash, '1', '1.5', '2'));
});
test('torrent export preserves binary bytes and renews expired authorization', async () => {
  const data = Uint8Array.from([100, 0, 255, 128, 101]).buffer;
  const { client, transport } = await connected('v5.0.4', [
    { status: 403, body: '', cookies: '' }, ok('Ok.', 'SID=new;'), { status: 200, body: '', cookies: '', data }
  ]);
  assert.deepEqual(new Uint8Array(await client.exportTorrent(hash)), new Uint8Array(data));
  assert.equal(transport.requests.at(-1).binary, true);
  assert.equal(transport.requests.at(-1).headers.Cookie, 'SID=new');
});
test('batch metadata updates send the complete explicit selection', async () => {
  const hashes = hash + '|' + 'b'.repeat(40);
  const { client, transport } = await connected('v5.0.4', [ok(), ok(), ok(), ok()]);
  await client.setCategory(hashes, 'Linux');
  await client.setLocation(hashes, '/downloads/Linux');
  await client.tags(hashes, 'iso,test', false);
  await client.action('topPrio', hashes.split('|'));
  for (const r of transport.requests.slice(2)) assert.equal(new URLSearchParams(r.body).get('hashes'), hashes);
});
