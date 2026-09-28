// SPDX-License-Identifier: GPL-3.0-only
import { TorrentFile } from './Models';

export interface FileNode {
  path: string; name: string; directory: boolean; depth: number;
  ids: number[]; size: number; progress: number; priority: number;
}

// Aggregate by path segments, never by a raw prefix (foo must not include foobar).
export function fileTree(files: TorrentFile[], expanded: string[]): FileNode[] {
  const nodes = new Map<string, FileNode>();
  for (const file of files) {
    const parts = file.name.split('/');
    for (let i = 0; i < parts.length; i++) {
      const path = parts.slice(0, i + 1).join('/');
      let node = nodes.get(path);
      if (!node) {
        node = { path: path, name: parts[i], directory: i < parts.length - 1, depth: i,
          ids: [], size: 0, progress: 0, priority: file.priority };
        nodes.set(path, node);
      }
      node.ids.push(file.index);
      node.size += file.size;
      node.progress += file.size * file.progress;
      if (node.priority !== file.priority) { node.priority = -1; }
    }
  }
  const result = Array.from(nodes.values());
  for (const node of result) { node.progress = node.size ? node.progress / node.size : 0; }
  result.sort((a: FileNode, b: FileNode): number => {
    const ap = a.path.split('/'); const bp = b.path.split('/');
    for (let i = 0; i < Math.min(ap.length, bp.length); i++) {
      if (ap[i] !== bp[i]) {
        const ad = i < ap.length - 1 || a.directory;
        const bd = i < bp.length - 1 || b.directory;
        return ad !== bd ? (ad ? -1 : 1) : ap[i].localeCompare(bp[i]);
      }
    }
    return ap.length - bp.length;
  });
  return result.filter((node: FileNode): boolean => {
    const parts = node.path.split('/');
    for (let i = 1; i < parts.length; i++) {
      if (!expanded.includes(parts.slice(0, i).join('/'))) { return false; }
    }
    return true;
  });
}

export function toggleFileSelection(selected: number[], ids: number[]): number[] {
  if (ids.every((id: number): boolean => selected.includes(id))) {
    return selected.filter((id: number): boolean => !ids.includes(id));
  }
  return Array.from(new Set<number>(selected.concat(ids)));
}

export function sharedLinks(text: string): string {
  return Array.from(new Set<string>(text.match(/(?:magnet:\?|https?:\/\/)[^\s<>"']+/gi) || [])).join('\n');
}
