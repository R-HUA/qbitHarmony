// SPDX-License-Identifier: GPL-3.0-only
export interface ServerProfile {
  id: string;
  name: string;
  url: string;
  username: string;
  remember: boolean;
}
export interface AppSettings {
  rememberServer: boolean;
  hideUrls: boolean;
  lastServerId: string;
  refreshSeconds: number;
  timeoutSeconds: number;
  theme: number;
  sort?: number;
  reverseSort?: boolean;
}

export interface Torrent {
  hash: string;
  name: string;
  size: number;
  progress: number;
  dlspeed: number;
  upspeed: number;
  state: string;
  ratio: number;
  eta: number;
  category: string;
  tags: string;
  save_path: string;
  num_seeds: number;
  num_leechs: number;
  added_on: number;
  priority?: number;
  completion_on?: number;
  last_activity?: number;
  time_active?: number;
  seeding_time?: number;
  downloaded_session?: number;
  uploaded_session?: number;
  seen_complete?: number;
  downloaded?: number;
  uploaded?: number;
  num_complete?: number;
  num_incomplete?: number;
  trackers_count?: number;
  force_start?: boolean;
  seq_dl?: boolean;
  f_l_piece_prio?: boolean;
  auto_tmm?: boolean;
  magnet_uri?: string;
  dl_limit?: number;
  up_limit?: number;
  ratio_limit?: number;
  seeding_time_limit?: number;
  inactive_seeding_time_limit?: number;
}

export interface Transfer {
  dl_info_speed: number;
  up_info_speed: number;
  dl_info_data: number;
  up_info_data: number;
  dl_rate_limit: number;
  up_rate_limit: number;
  connection_status: string;
  use_alt_speed_limits?: boolean;
  use_subcategories?: boolean;
}
export interface AddOptions {
  tags: string;
  rename: string;
  sequential: boolean;
  firstLast: boolean;
  autoTmm: number;
  downloadLimit: string;
  uploadLimit: string;
}
export interface Category { name: string; savePath: string; }
export interface SyncPatch {
  rid: number;
  full_update?: boolean;
  torrents?: Record<string, Partial<Torrent>>;
  torrents_removed?: string[];
  server_state?: Partial<Transfer>;
  categories?: Record<string, Category>;
  categories_removed?: string[];
  tags?: string[];
  tags_removed?: string[];
  trackers?: Record<string, string[]>;
  trackers_removed?: string[];
}
export interface SyncSnapshot {
  rid: number;
  torrents: Torrent[];
  transfer: Transfer;
  categories: Category[];
  tags: string[];
  trackers: Record<string, string[]>;
}

export interface TorrentFile {
  index: number;
  name: string;
  size: number;
  progress: number;
  priority: number;
}

export interface Tracker {
  url: string;
  status: number;
  num_peers: number;
  msg: string;
}

export interface Field { name: string; value: string; }
export interface Upload { name: string; data: ArrayBuffer; }
export interface ApiRequest {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: string;
  fields: Field[];
  upload?: Upload;
  binary?: boolean;
}
export interface ApiResponse { status: number; body: string; cookies: string; data?: ArrayBuffer; }
export interface Transport { send(request: ApiRequest): Promise<ApiResponse>; }

export interface TorrentProperties { addition_date?: number; completion_date?: number; reannounce?: number; nb_connections?: number; nb_connections_limit?: number; total_wasted?: number; }
export interface TorrentPeer { ip: string; port: number; client: string; connection: string; flags: string; progress: number; dl_speed: number; up_speed: number; downloaded: number; uploaded: number; }
export interface TorrentPeers { peers?: Record<string, TorrentPeer>; }
