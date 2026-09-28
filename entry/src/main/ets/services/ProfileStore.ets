// SPDX-License-Identifier: GPL-3.0-only
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { AppSettings, ServerProfile } from '../core/Models';

export class ProfileStore {
  private encode(value: string): Uint8Array { return new util.TextEncoder().encodeInto(value); }
  private alias(id: string): Uint8Array { return this.encode('qbitharmony.password.' + id); }
  async loadSettings(context: common.UIAbilityContext): Promise<AppSettings> {
    try {
      const store = await preferences.getPreferences(context, { name: 'servers' });
      const defaults: AppSettings = { rememberServer: true, hideUrls: false, lastServerId: '', refreshSeconds: 5, timeoutSeconds: 10, theme: 0 };
      return JSON.parse(await store.get('settings', JSON.stringify(defaults)) as string) as AppSettings;
    } catch (error) { throw new Error('读取应用设置失败。'); }
  }
  async saveSettings(context: common.UIAbilityContext, settings: AppSettings): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, { name: 'servers' });
      await store.put('settings', JSON.stringify(settings));
      await store.flush();
    } catch (error) { throw new Error('保存应用设置失败。'); }
  }

  async load(context: common.Context): Promise<ServerProfile[]> {
    try {
      const store = await preferences.getPreferences(context, { name: 'servers' });
      return JSON.parse(await store.get('profiles', '[]') as string) as ServerProfile[];
    } catch (error) { throw new Error('读取服务器配置失败。'); }
  }
  async save(context: common.UIAbilityContext, profiles: ServerProfile[]): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, { name: 'servers' });
      await store.put('profiles', JSON.stringify(profiles));
      await store.flush();
    } catch (error) { throw new Error('保存服务器配置失败。'); }
  }
  async password(id: string): Promise<string> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, this.alias(id));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    let results: asset.AssetMap[];
    try { results = await asset.query(query); }
    catch (error) { throw new Error('无法读取安全存储中的密码，请解锁设备或重新输入。'); }
    if (!results.length) { return ''; }
    return new util.TextDecoder().decodeToString(results[0].get(asset.Tag.SECRET) as Uint8Array);
  }
  async putPassword(id: string, password: string): Promise<void> {
    const attrs: asset.AssetMap = new Map();
    attrs.set(asset.Tag.ALIAS, this.alias(id));
    attrs.set(asset.Tag.SECRET, this.encode(password));
    attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
    attrs.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    try { await asset.add(attrs); }
    catch (error) { throw new Error('无法安全保存密码，请解锁设备，或关闭“安全保存密码”后重试。'); }
  }
  async removePassword(id: string): Promise<void> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, this.alias(id));
    try { await asset.remove(query); }
    catch (error) { throw new Error('无法删除安全存储中的密码，请解锁设备后重试。'); }
  }
}
