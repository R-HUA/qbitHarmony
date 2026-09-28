// SPDX-License-Identifier: GPL-3.0-only
import { Torrent } from '../core/Models';

@Observed
export class TorrentRowData {
  torrent: Torrent;
  constructor(torrent: Torrent) { this.torrent = torrent; }
}

// Stable row identity; live values travel through @ObjectLink, not through keys.
export class TorrentRows implements IDataSource {
  private rows: TorrentRowData[] = [];
  private listeners: DataChangeListener[] = [];
  totalCount(): number { return this.rows.length; }
  getData(index: number): TorrentRowData { return this.rows[index]; }
  update(torrents: Torrent[]): void {
    const existing = new Map<string, TorrentRowData>();
    this.rows.forEach((row: TorrentRowData) => { existing.set(row.torrent.hash, row); });
    const orderChanged = torrents.length !== this.rows.length ||
      torrents.some((t: Torrent, i: number): boolean => this.rows[i]?.torrent.hash !== t.hash);
    this.rows = torrents.map((torrent: Torrent): TorrentRowData => {
      const row = existing.get(torrent.hash);
      if (row) { row.torrent = torrent; return row; }
      return new TorrentRowData(torrent);
    });
    if (orderChanged) { this.listeners.forEach((listener: DataChangeListener) => { listener.onDataReloaded(); }); }
  }
  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) { this.listeners.push(listener); }
  }
  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners = this.listeners.filter((item: DataChangeListener): boolean => item !== listener);
  }
}
