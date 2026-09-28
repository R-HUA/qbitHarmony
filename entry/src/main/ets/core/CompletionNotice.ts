// SPDX-License-Identifier: GPL-3.0-only
import { Torrent } from './Models';
export const NOTICE_MAX_AGE = 24 * 60 * 60 * 1000;
export interface NoticeEvent { hash: string; name: string; completedAt: number; }
export interface NoticeState {
  checkedAt: number; lastAlert: number; states: Record<string, string>;
  seen: Record<string, number>; pending: NoticeEvent[];
}
export interface NoticeResult { state: NoticeState; events: NoticeEvent[]; }
export function emptyNotice(): NoticeState { return { checkedAt: 0, lastAlert: 0, states: {}, seen: {}, pending: [] }; }
const COMPLETE = ['uploading', 'stalledUP', 'pausedUP', 'stoppedUP', 'forcedUP', 'queuedUP', 'checkingUP'];
const DOWNLOADING = ['downloading', 'stalledDL', 'pausedDL', 'stoppedDL', 'forcedDL', 'queuedDL', 'checkingDL', 'metaDL', 'forcedMetaDL'];

// checkedAt is captured before the HTTP request. Late snapshots cannot undo newer observations.
export function completionNotice(previous: NoticeState, torrents: Torrent[], checkedAt: number, now: number): NoticeResult {
  if (checkedAt <= previous.checkedAt && now >= previous.checkedAt) { return { state: previous, events: [] }; }
  const rebase = !previous.checkedAt || now < previous.checkedAt || now - previous.checkedAt > NOTICE_MAX_AGE;
  const next: NoticeState = { checkedAt: checkedAt, lastAlert: rebase ? 0 : previous.lastAlert, states: {}, seen: {},
    pending: rebase ? [] : previous.pending.filter((e: NoticeEvent): boolean => now - e.completedAt <= NOTICE_MAX_AGE) };
  for (const t of torrents) {
    const hash = t.hash;
    if (!/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/i.test(hash)) { continue; }
    next.states[hash] = t.state;
    if (previous.seen[hash] !== undefined) { next.seen[hash] = previous.seen[hash]; }
    const complete = COMPLETE.includes(t.state) && t.progress >= 1;
    const stamp = (t.completion_on || 0) * 1000;
    if (rebase) { if (complete) { next.seen[hash] = stamp; } continue; }
    const transitioned = DOWNLOADING.includes(previous.states[hash]) ||
      (previous.states[hash] === undefined && t.added_on * 1000 >= previous.checkedAt - 1000);
    if (complete && transitioned && stamp > 0 && stamp >= now - NOTICE_MAX_AGE && stamp <= now + 60000 && next.seen[hash] !== stamp) {
      next.pending.push({ hash: hash, name: t.name, completedAt: stamp }); next.seen[hash] = stamp;
    }
  }
  next.pending = next.pending.filter((e: NoticeEvent): boolean => next.states[e.hash] !== undefined);
  let events: NoticeEvent[] = [];
  if (next.pending.length > 0 && now - next.lastAlert >= 60000) {
    events = next.pending; next.pending = []; next.lastAlert = now;
  }
  return { state: next, events: events };
}
