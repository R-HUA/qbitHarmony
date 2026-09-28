// SPDX-License-Identifier: GPL-3.0-only
import { Want } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { fileIo } from '@kit.CoreFileKit';
import { Upload } from '../core/Models';
import { sharedLinks } from '../core/FileTree';

export interface IncomingShare { links: string; upload?: Upload; error: string; }

export async function readTorrentUri(uri: string): Promise<Upload> {
  const file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
  try {
    const stat = await fileIo.stat(file.fd);
    if (stat.size <= 0 || stat.size > 10 * 1024 * 1024) { throw new Error('请选择小于 10 MiB 的种子文件。'); }
    const data = new ArrayBuffer(stat.size);
    const read = await fileIo.read(file.fd, data);
    if (read !== stat.size || new Uint8Array(data)[0] !== 100) { throw new Error('无法识别此种子文件。'); }
    return { name: 'shared.torrent', data: data };
  } finally { await fileIo.close(file); }
}

// Read temporary share URIs while the receiving ability still holds the grant.
export async function receiveShare(want: Want): Promise<void> {
  if (want.action !== 'ohos.want.action.sendData' && !want.uri?.startsWith('magnet:')) { return; }
  const incoming: IncomingShare = { links: '', error: '' };
  try {
    if (want.uri?.startsWith('magnet:')) { incoming.links = sharedLinks(want.uri); }
    else {
      const data = await systemShare.getSharedData(want);
      const records = data.getRecords();
      for (const record of records) {
        if (record.content) { incoming.links += '\n' + sharedLinks(record.content); }
        else if (record.uri) {
          if (incoming.upload) { throw new Error('一次只能添加一个种子文件。'); }
          incoming.upload = await readTorrentUri(record.uri);
        }
      }
      incoming.links = sharedLinks(incoming.links);
    }
    if (!incoming.links && !incoming.upload) { throw new Error('分享内容中没有磁力链接、HTTP(S) 链接或种子文件。'); }
  } catch (error) { incoming.error = (error as Error).message || '无法读取分享内容。'; }
  AppStorage.setOrCreate<IncomingShare>('incomingShare', incoming);
}
