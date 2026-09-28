// SPDX-License-Identifier: GPL-3.0-only
// Port of MainScreen's server selection lifecycle and ServerManager's order preservation.
import { ServerProfile } from './Models';
export function initialServer(profiles: ServerProfile[], lastId: string, remember: boolean): ServerProfile | undefined {
  return (remember ? profiles.find((p: ServerProfile) => p.id === lastId) : undefined) || profiles[0];
}
export function upsertServer(profiles: ServerProfile[], profile: ServerProfile): ServerProfile[] {
  return profiles.some((p: ServerProfile) => p.id === profile.id) ?
    profiles.map((p: ServerProfile) => p.id === profile.id ? profile : p) : profiles.concat([profile]);
}
export function serverAfterRemoval(profiles: ServerProfile[], removedId: string, currentId: string): ServerProfile | undefined {
  const remaining = profiles.filter((p: ServerProfile) => p.id !== removedId);
  return remaining.find((p: ServerProfile) => p.id === currentId) || remaining[0];
}
