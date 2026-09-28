// SPDX-License-Identifier: GPL-3.0-only
// Mirrors qBitController MainData.merge: full snapshot, rid ordering, sparse updates and removals.
import { Category, SyncPatch, SyncSnapshot, Torrent, Transfer } from './Models';
export class SyncState {
  private rid: number = 0;
  private torrents: Map<string, Torrent> = new Map();
  private categories: Map<string, Category> = new Map();
  private tags: Set<string> = new Set();
  private trackers: Record<string, string[]> = {};
  private transfer: Transfer = this.emptyTransfer();
  private emptyTransfer(): Transfer {
    return { dl_info_speed: 0, up_info_speed: 0, dl_info_data: 0, up_info_data: 0,
      dl_rate_limit: 0, up_rate_limit: 0, connection_status: '' };
  }
  revision(): number { return this.rid; }
  merge(patch: SyncPatch): SyncSnapshot {
    if (!Number.isFinite(patch.rid)) { throw new Error('服务器增量数据格式无效。'); }
    if (!patch.full_update && patch.rid < this.rid) { return this.snapshot(); }
    if (patch.full_update) {
      this.torrents.clear(); this.categories.clear(); this.tags.clear(); this.trackers = {}; this.transfer = this.emptyTransfer();
    }
    this.rid = patch.rid;
    if (patch.torrents) {
      for (const hash of Object.keys(patch.torrents)) {
        const defaults: Torrent = { hash, name: '', size: 0, progress: 0, dlspeed: 0, upspeed: 0, state: 'unknown',
          ratio: 0, eta: 8640000, category: '', tags: '', save_path: '', num_seeds: 0, num_leechs: 0, added_on: 0 };
        this.torrents.set(hash, { ...(this.torrents.get(hash) || defaults), ...patch.torrents[hash], hash });
      }
    }
    (patch.torrents_removed || []).forEach((hash: string) => this.torrents.delete(hash));
    this.transfer = { ...this.transfer, ...patch.server_state };
    if (patch.categories) {
      for (const name of Object.keys(patch.categories)) { this.categories.set(name, patch.categories[name]); }
    }
    (patch.categories_removed || []).forEach((name: string) => this.categories.delete(name));
    (patch.tags || []).forEach((tag: string) => this.tags.add(tag));
    (patch.tags_removed || []).forEach((tag: string) => this.tags.delete(tag));
    this.trackers = { ...this.trackers, ...patch.trackers };
    (patch.trackers_removed || []).forEach((name: string) => { delete this.trackers[name]; });
    return this.snapshot();
  }
  private snapshot(): SyncSnapshot {
    return { rid: this.rid, torrents: Array.from(this.torrents.values()), transfer: { ...this.transfer },
      categories: Array.from(this.categories.values()).sort((a: Category, b: Category) => a.name.localeCompare(b.name)),
      tags: Array.from(this.tags.values()).sort(), trackers: { ...this.trackers } };
  }
}
