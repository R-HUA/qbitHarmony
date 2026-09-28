// SPDX-License-Identifier: GPL-3.0-only
import { Torrent } from './Models';
export const FILTER_LABELS: string[] = ['全部', '下载中', '做种中', '已暂停', '错误', '已完成', '已启动', '活跃', '不活跃', '停滞', '校验中', '移动中'];
export const SORT_LABELS: string[] = ['添加时间', '名称', '下载速度', '进度', '大小', '上传速度', '分享率', '剩余时间', '优先级', '状态', 'Hash', '连接种子数', '总种子数', '连接用户数', '总用户数', '完成时间', '最后活动', '已下载', '已上传'];

export function bytes(value: number): string {
  if (!Number.isFinite(value) || value <= 0) { return '0 B'; }
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  const index = Math.min(Math.floor(Math.log(value) / Math.log(1024)), 4);
  return `${(value / Math.pow(1024, index)).toFixed(index === 0 ? 0 : 1)} ${units[index]}`;
}
export function percent(value: number): number {
  return Math.round(Math.max(0, Math.min(1, value || 0)) * 1000) / 10;
}
export function duration(seconds: number): string {
  if (seconds < 0 || seconds >= 8640000 || !Number.isFinite(seconds)) { return '—'; }
  if (seconds < 60) { return `${seconds} 秒`; }
  if (seconds < 3600) { return `${Math.floor(seconds / 60)} 分钟`; }
  if (seconds < 86400) { return `${Math.floor(seconds / 3600)} 小时`; }
  return `${Math.floor(seconds / 86400)} 天`;
}
export function isStopped(state: string): boolean {
  return state.startsWith('paused') || state.startsWith('stopped');
}
export function stateLabel(state: string): string {
  if (isStopped(state)) { return '已暂停'; }
  if (state === 'error' || state === 'missingFiles') { return '异常'; }
  if (state.startsWith('checking')) { return '校验中'; }
  if (state.startsWith('queued')) { return '排队中'; }
  if (state === 'metaDL' || state === 'forcedMetaDL') { return '获取元数据'; }
  if (state === 'stalledDL') { return '等待下载'; }
  if (state.endsWith('DL') || state === 'downloading') { return '下载中'; }
  if (state.endsWith('UP') || state === 'uploading') { return '做种中'; }
  if (state === 'moving') { return '移动中'; }
  return state;
}
export function selectTorrents(items: Torrent[], query: string, filter: number, sort: number,
  category: string = '', tag: string = '', reverse: boolean = false, subcategories: boolean = false,
  tracker: string = '', trackerMap: Record<string, string[]> = {}): Torrent[] {
  const terms = query.toLowerCase().split(/\s+/).filter((s: string) => s !== '' && s !== '-');
  const result = items.filter((t: Torrent) => {
    if (!terms.every((term: string) => term.startsWith('-') ? !t.name.toLowerCase().includes(term.slice(1)) : t.name.toLowerCase().includes(term))) { return false; }
    if (category === '\u0000' && t.category) { return false; }
    if (category && category !== '\u0000' && (subcategories ? !(t.category + '/').startsWith(category + '/') : t.category !== category)) { return false; }
    if (tag === '\u0000' && t.tags) { return false; }
    if (tag && tag !== '\u0000' && !t.tags.split(',').map((s: string) => s.trim()).includes(tag)) { return false; }
    if (tracker === '\u0000' && (t.trackers_count || 0) !== 0) { return false; }
    if (tracker && tracker !== '\u0000' && !(trackerMap[tracker] || []).includes(t.hash)) { return false; }
    const state = t.state.replace('stopped', 'paused');
    const downloading = ['downloading', 'checkingDL', 'stalledDL', 'forcedDL', 'queuedDL', 'metaDL', 'forcedMetaDL', 'pausedDL'];
    const seeding = ['uploading', 'checkingUP', 'stalledUP', 'forcedUP', 'queuedUP'];
    if (filter === 1) { return downloading.includes(state); }
    if (filter === 2) { return seeding.includes(state); }
    if (filter === 3) { return isStopped(t.state); }
    if (filter === 4) { return t.state === 'error' || t.state === 'missingFiles'; }
    if (filter === 5) { return seeding.includes(state) || state === 'pausedUP'; }
    if (filter === 6) { return (downloading.includes(state) || seeding.includes(state)) && !isStopped(state); }
    if (filter === 7) { return t.dlspeed > 0 || t.upspeed > 0; }
    if (filter === 8) { return t.dlspeed === 0 && t.upspeed === 0; }
    if (filter === 9) { return state.startsWith('stalled'); }
    if (filter === 10) { return state.startsWith('checking'); }
    if (filter === 11) { return state === 'moving'; }
    return true;
  });
  return result.sort((a: Torrent, b: Torrent) => {
    let diff = 0;
    if (sort === 1) { diff = a.name.toLowerCase().localeCompare(b.name.toLowerCase()); }
    else if (sort === 9) { diff = a.state.localeCompare(b.state); }
    else if (sort === 10) { diff = a.hash.localeCompare(b.hash); }
    else {
      const av = [a.added_on, 0, a.dlspeed, a.progress, a.size, a.upspeed, a.ratio, a.eta, a.priority || 0, 0, 0, a.num_seeds, a.num_complete || 0, a.num_leechs, a.num_incomplete || 0, a.completion_on || 0, a.last_activity || 0, a.downloaded || 0, a.uploaded || 0];
      const bv = [b.added_on, 0, b.dlspeed, b.progress, b.size, b.upspeed, b.ratio, b.eta, b.priority || 0, 0, 0, b.num_seeds, b.num_complete || 0, b.num_leechs, b.num_incomplete || 0, b.completion_on || 0, b.last_activity || 0, b.downloaded || 0, b.uploaded || 0];
      const missingA = (sort === 7 && (a.eta < 0 || a.eta >= 8640000)) || (sort === 8 && !a.priority) || (sort === 15 && !a.completion_on);
      const missingB = (sort === 7 && (b.eta < 0 || b.eta >= 8640000)) || (sort === 8 && !b.priority) || (sort === 15 && !b.completion_on);
      diff = missingA !== missingB ? (missingA ? 1 : -1) : missingA ? 0 : sort === 16 ? bv[sort] - av[sort] : av[sort] - bv[sort];
    }
    if (diff === 0) { diff = a.name.toLowerCase().localeCompare(b.name.toLowerCase()) || a.hash.localeCompare(b.hash); }
    return reverse ? -diff : diff;
  });
}
