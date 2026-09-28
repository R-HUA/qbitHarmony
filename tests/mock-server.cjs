// Local-only device smoke-test server. No downloads and no real files are modified.
// hdc -t <device> rport tcp:18080 tcp:18080 forwards device localhost to this server.
const http = require('node:http');
let torrents = [
  { hash: 'a'.repeat(40), name: 'Ubuntu 26.04 Desktop amd64.iso', size: 6442450944, progress: .624,
    dlspeed: 12582912, upspeed: 1048576, state: 'downloading', ratio: .18, eta: 185,
    category: 'Linux', tags: 'iso, official', save_path: '/downloads/Linux', num_seeds: 42, num_leechs: 8, added_on: 100 },
  { hash: 'b'.repeat(40), name: 'Debian 13 netinst amd64.iso', size: 805306368, progress: 1,
    dlspeed: 0, upspeed: 2097152, state: 'uploading', ratio: 2.4, eta: 8640000,
    category: 'Linux', tags: 'iso', save_path: '/downloads/Linux', num_seeds: 19, num_leechs: 3, added_on: 90 },
  { hash: 'c'.repeat(40), name: 'Fedora Workstation Live.iso', size: 2684354560, progress: .12,
    dlspeed: 0, upspeed: 0, state: 'stoppedDL', ratio: 0, eta: 8640000,
    category: '', tags: '', save_path: '/downloads', num_seeds: 0, num_leechs: 0, added_on: 80 }
];
torrents = torrents.map(t => ({ ...t, added_on: 1790409600, time_active: 96500, seeding_time: 7200, downloaded: 4000000000, downloaded_session: 500000000, uploaded: 700000000, uploaded_session: 100000000, last_activity: 1790420400 }));
let dlLimit = 0, upLimit = 0, priority = 1;
let rid = 0;
const files = [
  { index: 7, name: 'Linux/ISO/Ubuntu.iso', size: 6000000, progress: .5, priority: 1 },
  { index: 12, name: 'Linux/ISO/Debian.iso', size: 3000000, progress: 1, priority: 6 },
  { index: 99, name: 'Linux/README.txt', size: 1024, progress: 1, priority: 1 },
  ...Array.from({ length: 18 }, (_, i) => ({ index: i + 100, name: `Documents/Chapter-${i + 1}.txt`, size: 2048, progress: .25, priority: 1 }))
];
for (const t of torrents) Object.assign(t, { magnet_uri: `magnet:?xt=urn:btih:${t.hash}&dn=SmokeTest`, dl_limit: 131072, up_limit: 65536, ratio_limit: 1.5, seeding_time_limit: 1440, inactive_seeding_time_limit: -2 });
const server = http.createServer(async (req, res) => {
  try {
    const chunks = []; for await (const chunk of req) chunks.push(chunk);
    const body = Buffer.concat(chunks);
    const path = req.url.split('?')[0].replace('/api/v2/', '');
    const respond = (data, code = 200) => {
      res.writeHead(code, { 'Content-Type': typeof data === 'string' ? 'text/plain' : 'application/json' });
      res.end(typeof data === 'string' ? data : JSON.stringify(data));
    };
    if (path === 'auth/login') {
      const form = new URLSearchParams(body.toString());
      if (form.get('username') !== 'test' || form.get('password') !== 'test') return respond('Fails.');
      res.setHeader('Set-Cookie', 'SID=smoke-session; HttpOnly; Path=/');
      console.log('LOGIN OK'); return respond('Ok.');
    }
    if (!req.headers.cookie?.includes('SID=smoke-session')) { console.log('MISSING SID'); return respond('Forbidden', 403); }
    if (req.headers.referer !== 'http://127.0.0.1:18080/') { console.log('BAD REFERER'); return respond('Bad referer', 403); }
    const form = new URLSearchParams(body.toString());
    if (path === 'app/version') return respond('v5.1.2');
    if (path === 'torrents/info') return respond(torrents);
    if (path === 'sync/maindata') return respond({ rid: ++rid, full_update: true,
      torrents: Object.fromEntries(torrents.map(t=>[t.hash,t])),
      server_state: { dl_info_speed: torrents.reduce((n,t)=>n+t.dlspeed,0), up_info_speed: 3145728,
        dl_info_data: 1099511627776, up_info_data: 219902325555, dl_rate_limit: dlLimit, up_rate_limit: upLimit, connection_status: 'connected' },
      categories: { Linux: { name: 'Linux', savePath: '/downloads/Linux' } }, tags: ['iso','official'],
      trackers: { 'https://tracker.example.org/announce': torrents.map(t=>t.hash) } });
    if (path === 'transfer/info') return respond({ dl_info_speed: torrents.reduce((n,t)=>n+t.dlspeed,0),
      up_info_speed: 3145728, dl_info_data: 1099511627776, up_info_data: 219902325555,
      dl_rate_limit: dlLimit, up_rate_limit: upLimit, connection_status: 'connected' });
    if (path === 'torrents/properties') return respond({ addition_date: 1790409600, completion_date: -1, reannounce: 120, nb_connections: 12, nb_connections_limit: 100, total_wasted: 2048 });
    if (path === 'sync/torrentPeers') return respond({ full_update: true, rid: 1, peers: {
      '192.0.2.10:51413': { ip: '192.0.2.10', port: 51413, client: 'qBittorrent 5.1.2', connection: 'BT', flags: 'D U E', progress: .82, dl_speed: 1048576, up_speed: 524288, downloaded: 300000000, uploaded: 50000000 },
      '[2001:db8::1]:6881': { ip: '2001:db8::1', port: 6881, client: 'Transmission 4', connection: 'uTP', flags: 'D E', progress: 1, dl_speed: 2097152, up_speed: 0, downloaded: 700000000, uploaded: 0 }
    }});
    if (path === 'torrents/files') return respond(files);
    if (path === 'torrents/export') {
      const data = Buffer.concat([Buffer.from('d4:infod6:lengthi1e4:name9:SmokeTest12:piece lengthi16384e6:pieces20:'), require('node:crypto').createHash('sha1').update(Buffer.from([0])).digest(), Buffer.from('ee')]);
      res.writeHead(200, { 'Content-Type': 'application/x-bittorrent' }); return res.end(data);
    }
    if (path === 'torrents/trackers') return respond([{ url: 'https://tracker.example.org/announce', status: 2, num_peers: 50, msg: '' }]);
    if (req.method !== 'POST') return respond('Not found', 404);
    console.log('MUTATION', path);
    console.log('FIELDS', JSON.stringify(Object.fromEntries(form)));
    const selected = torrents.filter(t => (form.get('hashes') || '').split('|').includes(t.hash));
    if (path === 'torrents/stop') selected.forEach(t => { t.state = 'stoppedDL'; t.dlspeed = 0; });
    else if (path === 'torrents/start') selected.forEach(t => { t.state = 'downloading'; t.dlspeed = 12582912; });
    else if (path === 'torrents/recheck' || path === 'torrents/reannounce') {}
    else if (path === 'torrents/delete') {
      console.log('DELETE_FILES', form.get('deleteFiles'));
      torrents = torrents.filter(t => !selected.includes(t));
    } else if (path === 'torrents/setCategory') selected.forEach(t => { t.category = form.get('category'); });
    else if (path === 'torrents/filePrio') files.filter(f => form.get('id').split('|').includes(String(f.index))).forEach(f => f.priority = Number(form.get('priority')));
    else if (path === 'torrents/setDownloadLimit') selected.forEach(t => t.dl_limit = Number(form.get('limit')));
    else if (path === 'torrents/setUploadLimit') selected.forEach(t => t.up_limit = Number(form.get('limit')));
    else if (path === 'torrents/setShareLimits') selected.forEach(t => Object.assign(t, { ratio_limit: Number(form.get('ratioLimit')), seeding_time_limit: Number(form.get('seedingTimeLimit')), inactive_seeding_time_limit: Number(form.get('inactiveSeedingTimeLimit')) }));
    else if (path === 'torrents/setLocation') selected.forEach(t => t.save_path = form.get('location'));
    else if (path === 'torrents/addTags') selected.forEach(t => t.tags = form.get('tags'));
    else if (path === 'torrents/removeTags') selected.forEach(t => t.tags = '');
    else if (['torrents/topPrio', 'torrents/bottomPrio', 'torrents/increasePrio', 'torrents/decreasePrio'].includes(path)) {}
    else if (path === 'transfer/setDownloadLimit') dlLimit = Number(form.get('limit'));
    else if (path === 'transfer/setUploadLimit') upLimit = Number(form.get('limit'));
    else if (path === 'torrents/add') {
      const multipart = new Request('http://localhost', { method: 'POST', headers: req.headers, body });
      const data = await multipart.formData();
      if (!data.get('urls') && !data.get('torrents')) return respond('Fails.');
      torrents.push({ ...torrents[0], hash: 'd'.repeat(40), name: '新添加的测试任务.iso', progress: 0,
        category: data.get('category') || '', state: data.get('stopped') === 'true' ? 'stoppedDL' : 'downloading' });
      return respond('Ok.');
    } else return respond('Not found', 404);
    respond('');
  } catch (error) { console.error(error.message); res.writeHead(500); res.end('Mock error'); }
});
server.listen(18080, '127.0.0.1', () => console.log('Mock qBittorrent on 127.0.0.1:18080 (test/test)'));
