// SPDX-License-Identifier: GPL-3.0-only
import { TorrentProperties, TorrentPeer, TorrentPeers, AddOptions, ApiRequest, ApiResponse, Field, ServerProfile, SyncPatch, SyncSnapshot, Torrent, TorrentFile, Tracker, Transfer, Transport, Upload } from './Models';
import { SyncState } from './SyncState';

export function normalizeBaseUrl(input: string): string {
  const base = input.trim().replace(/\/+$/, '');
  if (!/^https?:\/\/[^\s/?#@]+(?:\/[^\s?#]*)?$/i.test(base)) {
    throw new Error('请输入完整的 http:// 或 https:// 地址，不含账号、查询参数或 #。');
  }
  if (/\/api\/v2$/i.test(base)) { throw new Error('填写 WebUI 地址即可，无需附加 /api/v2。'); }
  return base;
}
export function formEncode(fields: Field[]): string {
  return fields.map((f: Field) => `${encodeURIComponent(f.name)}=${encodeURIComponent(f.value)}`).join('&');
}
export function extractSid(cookies: string): string {
  const header = cookies.match(/(?:^|[;,\s])SID=([^;\s,]+)/);
  if (header) { return `SID=${header[1]}`; }
  // Some NetworkKit versions expose curl's Netscape cookie jar format.
  const lines = cookies.split(/\r?\n/);
  for (const line of lines) {
    const columns = line.split('\t');
    if (columns.length >= 7 && columns[5] === 'SID') { return `SID=${columns[6]}`; }
  }
  return '';
}
export class QbitClient {
  private base: string;
  private cookie: string = '';
  private password: string;
  private version: string = '';
  private authTask: Promise<void> | undefined = undefined;
  private syncState: SyncState = new SyncState();
  constructor(private profile: ServerProfile, password: string, private transport: Transport) {
    this.base = normalizeBaseUrl(profile.url);
    this.password = password;
  }

  private async raw(path: string, fields: Field[], method: string, upload?: Upload, binary: boolean = false): Promise<ApiResponse> {
    const headers: Record<string, string> = { 'Referer': this.base + '/', 'Cookie': this.cookie };
    if (!upload && path !== 'torrents/add') { headers['Content-Type'] = 'application/x-www-form-urlencoded'; }
    const query = method === 'GET' && fields.length ? '?' + formEncode(fields) : '';
    const request: ApiRequest = {
      url: this.base + '/api/v2/' + path + query, method: method, headers: headers,
      body: method === 'GET' ? '' : formEncode(fields), fields: path === 'torrents/add' ? fields : [], upload: upload, binary: binary
    };
    return this.transport.send(request);
  }

  private async authenticate(): Promise<void> {
    this.cookie = '';
    if (!this.profile.username && !this.password) { return; }
    const response = await this.raw('auth/login', [
      { name: 'username', value: this.profile.username }, { name: 'password', value: this.password }
    ], 'POST');
    if (response.status === 403) { throw new Error('登录被拒绝，请检查 WebUI IP 封禁或反向代理配置。'); }
    if (response.status !== 200 || response.body.trim() !== 'Ok.') {
      throw new Error('登录失败，请检查服务器地址、用户名和密码。');
    }
    this.cookie = extractSid(response.cookies);
  }

  private async ensureAuth(): Promise<void> {
    if (!this.authTask) { this.authTask = this.authenticate(); }
    try { await this.authTask; } finally { this.authTask = undefined; }
  }

  async connect(): Promise<string> {
    await this.ensureAuth();
    this.version = (await this.request('app/version')).trim();
    if (!/^v?\d+\.\d+/.test(this.version)) { throw new Error('服务器未返回有效的 qBittorrent 版本。'); }
    return this.version;
  }

  async request(path: string, fields: Field[] = [], method: string = 'GET', upload?: Upload): Promise<string> {
    let response = await this.raw(path, fields, method, upload);
    // Only retry a rejected authorization; never replay a mutation after a timeout.
    if (response.status === 403) {
      await this.ensureAuth();
      response = await this.raw(path, fields, method, upload);
    }
    if (response.status < 200 || response.status >= 300) {
      throw new Error(`请求失败（HTTP ${response.status}）。请检查 WebUI 权限、地址和网络。`);
    }
    return response.body;
  }

  async torrents(): Promise<Torrent[]> { return JSON.parse(await this.request('torrents/info')) as Torrent[]; }
  async sync(): Promise<SyncSnapshot> {
    const patch = JSON.parse(await this.request('sync/maindata', [{ name: 'rid', value: String(this.syncState.revision()) }])) as SyncPatch;
    return this.syncState.merge(patch);
  }
  async transfer(): Promise<Transfer> { return JSON.parse(await this.request('transfer/info')) as Transfer; }
  async files(hash: string): Promise<TorrentFile[]> {
    return JSON.parse(await this.request('torrents/files', [{ name: 'hash', value: hash }])) as TorrentFile[];
  }
  async trackers(hash: string): Promise<Tracker[]> {
    return JSON.parse(await this.request('torrents/trackers', [{ name: 'hash', value: hash }])) as Tracker[];
  }
  async properties(hash: string): Promise<TorrentProperties> {
    return JSON.parse(await this.request('torrents/properties', [{ name: 'hash', value: hash }])) as TorrentProperties;
  }
  async peers(hash: string): Promise<TorrentPeer[]> {
    // A full snapshot drops disconnected peers on each refresh.
    const result = JSON.parse(await this.request('sync/torrentPeers', [{ name: 'hash', value: hash }, { name: 'rid', value: '0' }])) as TorrentPeers;
    return Object.values(result.peers || {});
  }
  async action(action: string, hashes: string[]): Promise<void> {
    if (hashes.length === 0 || hashes.some((hash: string) => !/^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$/.test(hash))) {
      throw new Error('请选择有效任务。');
    }
    let endpoint = action;
    const major = parseInt(this.version.replace(/^v/, '').split('.')[0]);
    if (action === 'start') { endpoint = major >= 5 ? 'start' : 'resume'; }
    if (action === 'stop') { endpoint = major >= 5 ? 'stop' : 'pause'; }
    if (!['start', 'stop', 'resume', 'pause', 'recheck', 'reannounce', 'increasePrio', 'decreasePrio', 'topPrio', 'bottomPrio', 'toggleSequentialDownload', 'toggleFirstLastPiecePrio'].includes(endpoint)) {
      throw new Error('不支持的任务操作。');
    }
    await this.request('torrents/' + endpoint, [{ name: 'hashes', value: hashes.join('|') }], 'POST');
  }
  async remove(hash: string, deleteFiles: boolean): Promise<void> {
    if (!/^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$/.test(hash)) { throw new Error('请选择有效任务。'); }
    await this.request('torrents/delete', [
      { name: 'hashes', value: hash }, { name: 'deleteFiles', value: String(deleteFiles) }
    ], 'POST');
  }
  async removeMany(hashes: string[], deleteFiles: boolean): Promise<void> {
    if (!hashes.length || hashes.some((hash: string) => !/^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$/.test(hash))) { throw new Error('请选择有效任务。'); }
    await this.request('torrents/delete', [{ name: 'hashes', value: hashes.join('|') }, { name: 'deleteFiles', value: String(deleteFiles) }], 'POST');
  }
  async add(urls: string, savepath: string, category: string, stopped: boolean, upload?: Upload, options?: AddOptions): Promise<void> {
    const links = urls.split(/\r?\n/).map((v: string) => v.trim()).filter((v: string) => v.length > 0);
    if (!upload && (!links.length || links.some((v: string) => !/^(magnet:\?|https?:\/\/)/i.test(v)))) {
      throw new Error('请填写磁力链接或 HTTP(S) 种子地址，每行一个；也可以选择 .torrent 文件。');
    }
    const major = parseInt(this.version.replace(/^v/, '').split('.')[0]);
    const fields: Field[] = [
      { name: major >= 5 ? 'stopped' : 'paused', value: String(stopped) }
    ];
    if (!upload) { fields.push({ name: 'urls', value: links.join('\n') }); }
    if (savepath.trim() && options?.autoTmm !== 2) { fields.push({ name: 'savepath', value: savepath.trim() }); }
    if (category.trim()) { fields.push({ name: 'category', value: category.trim() }); }
    if (options) {
      if (options.tags.trim()) { fields.push({ name: 'tags', value: options.tags.trim() }); }
      if (options.rename.trim()) { fields.push({ name: 'rename', value: options.rename.trim() }); }
      fields.push({ name: 'sequentialDownload', value: String(options.sequential) });
      fields.push({ name: 'firstLastPiecePrio', value: String(options.firstLast) });
      if (options.autoTmm > 0) { fields.push({ name: 'autoTMM', value: String(options.autoTmm === 2) }); }
      if (options.downloadLimit) { fields.push({ name: 'dlLimit', value: this.limitValue(options.downloadLimit) }); }
      if (options.uploadLimit) { fields.push({ name: 'upLimit', value: this.limitValue(options.uploadLimit) }); }
    }
    const result = await this.request('torrents/add', fields, 'POST', upload);
    if (result.trim() !== 'Ok.') { throw new Error('服务器未接受种子，请检查链接或种子文件。'); }
  }
  async setCategory(hash: string, category: string): Promise<void> {
    await this.request('torrents/setCategory', [{ name: 'hashes', value: hash }, { name: 'category', value: category }], 'POST');
  }
  async setFilePriority(hash: string, id: number, priority: number): Promise<void> {
    await this.setFilePriorities(hash, [id], priority);
  }
  async setFilePriorities(hash: string, ids: number[], priority: number): Promise<void> {
    if (!ids.length || ids.some((id: number): boolean => !Number.isInteger(id) || id < 0) || ![0, 1, 6, 7].includes(priority)) {
      throw new Error('请选择文件和有效优先级。');
    }
    await this.request('torrents/filePrio', [
      { name: 'hash', value: hash }, { name: 'id', value: ids.join('|') }, { name: 'priority', value: String(priority) }
    ], 'POST');
  }
  async setTorrentLimit(hash: string, direction: string, kib: string): Promise<void> {
    if (!['Download', 'Upload'].includes(direction)) { throw new Error('无效限速方向。'); }
    await this.request('torrents/set' + direction + 'Limit', [
      { name: 'hashes', value: hash }, { name: 'limit', value: this.limitValue(kib) }
    ], 'POST');
  }
  async setShareLimits(hash: string, ratio: string, minutes: string, inactive: string): Promise<void> {
    if (!/^(?:-1|-2|\d+(?:\.\d+)?)$/.test(ratio) || !/^(?:-1|-2|\d+)$/.test(minutes) ||
      !/^(?:-1|-2|\d+)$/.test(inactive) || Number(ratio) > 1000000 || Number(minutes) > 2147483647 || Number(inactive) > 2147483647) {
      throw new Error('做种规则数值无效。');
    }
    await this.request('torrents/setShareLimits', [
      { name: 'hashes', value: hash }, { name: 'ratioLimit', value: ratio },
      { name: 'seedingTimeLimit', value: minutes }, { name: 'inactiveSeedingTimeLimit', value: inactive }
    ], 'POST');
  }
  async exportTorrent(hash: string): Promise<ArrayBuffer> {
    const fields: Field[] = [{ name: 'hash', value: hash }];
    let response = await this.raw('torrents/export', fields, 'GET', undefined, true);
    if (response.status === 403) { await this.ensureAuth(); response = await this.raw('torrents/export', fields, 'GET', undefined, true); }
    if (response.status !== 200 || !response.data || response.data.byteLength === 0) {
      throw new Error('种子导出失败，服务器可能不支持导出，或任务尚未获取元数据。');
    }
    return response.data;
  }
  async setLimit(direction: string, kib: string): Promise<void> {
    if (direction !== 'Download' && direction !== 'Upload') { throw new Error('无效限速方向。'); }
    await this.request(`transfer/set${direction}Limit`, [{ name: 'limit', value: this.limitValue(kib) }], 'POST');
  }
  private limitValue(kib: string): string {
    if (!/^\d+$/.test(kib) || Number(kib) > 10000000) { throw new Error('限速请输入 0 至 10000000 的整数（KiB/s）。'); }
    return String(Number(kib) * 1024);
  }
  async rename(hash: string, name: string): Promise<void> {
    if (!name.trim()) { throw new Error('名称不能为空。'); }
    await this.request('torrents/rename', [{ name: 'hash', value: hash }, { name: 'name', value: name.trim() }], 'POST');
  }
  async setLocation(hash: string, location: string): Promise<void> {
    if (!location.trim()) { throw new Error('路径不能为空。'); }
    await this.request('torrents/setLocation', [{ name: 'hashes', value: hash }, { name: 'location', value: location.trim() }], 'POST');
  }
  async forceStart(hash: string, enabled: boolean): Promise<void> {
    await this.request('torrents/setForceStart', [{ name: 'hashes', value: hash }, { name: 'value', value: String(enabled) }], 'POST');
  }
  async tags(hash: string, tags: string, remove: boolean): Promise<void> {
    await this.request(remove ? 'torrents/removeTags' : 'torrents/addTags', [{ name: 'hashes', value: hash }, { name: 'tags', value: tags }], 'POST');
  }
}
