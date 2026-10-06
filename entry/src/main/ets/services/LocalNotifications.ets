// SPDX-License-Identifier: GPL-3.0-only
import { notificationManager } from '@kit.NotificationKit';
import { common, wantAgent } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { workScheduler } from '@kit.BackgroundTasksKit';
import { NoticeState, emptyNotice, completionNotice, NoticeEvent } from '../core/CompletionNotice';
import { ServerProfile, Torrent } from '../core/Models';

const WORK_ID = 2710;
function workInfo(): workScheduler.WorkInfo {
  return { workId: WORK_ID, bundleName: 'com.personal.qbitharmony', abilityName: 'NotificationWorker',
    networkType: workScheduler.NetworkType.NETWORK_TYPE_ANY, isRepeat: true, repeatCycleTime: 7200000, isPersisted: true };
}
async function database(context: common.Context): Promise<relationalStore.RdbStore> {
  const db = await relationalStore.getRdbStore(context, { name: 'local_notifications.db', securityLevel: relationalStore.SecurityLevel.S1 });
  await db.executeSql('CREATE TABLE IF NOT EXISTS notices (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
  return db;
}
async function value(tx: relationalStore.Transaction, key: string): Promise<string> {
  const rows = await tx.querySql('SELECT value FROM notices WHERE key=?', [key]);
  try { return rows.goToFirstRow() ? rows.getString(0) : ''; } finally { rows.close(); }
}
export async function notificationsEnabled(context: common.Context): Promise<boolean> {
  const db = await database(context);
  const rows = await db.querySql('SELECT value FROM notices WHERE key=?', ['enabled']);
  try { return rows.goToFirstRow() && rows.getString(0) === 'true'; } finally { rows.close(); }
}
export async function restoreNotificationWork(context: common.Context): Promise<void> {
  if (!await notificationsEnabled(context)) { return; }
  const works = await workScheduler.obtainAllWorks();
  if (!works.some((w: workScheduler.WorkInfo): boolean => w.workId === WORK_ID)) { workScheduler.startWork(workInfo()); }
}
export async function setNotifications(context: common.UIAbilityContext, enabled: boolean): Promise<void> {
  if (enabled) {
    if (!await notificationManager.isNotificationEnabled()) { await notificationManager.requestEnableNotification(context); }
    if (!await notificationManager.isNotificationEnabled()) { throw new Error('请先在系统设置中允许通知。'); }
    const works = await workScheduler.obtainAllWorks();
    if (!works.some((w: workScheduler.WorkInfo): boolean => w.workId === WORK_ID)) { workScheduler.startWork(workInfo()); }
  }
  const db = await database(context);
  const tx = await db.createTransaction({ transactionType: relationalStore.TransactionType.IMMEDIATE });
  try {
    if ((await value(tx, 'enabled') === 'true') !== enabled) { await tx.execute('DELETE FROM notices'); }
    await tx.execute('INSERT OR REPLACE INTO notices(key,value) VALUES (?,?)', ['enabled', String(enabled)]);
    await tx.commit();
  } catch (error) { await tx.rollback(); throw error as Error; }
  if (!enabled) {
    const works = await workScheduler.obtainAllWorks();
    if (works.some((w: workScheduler.WorkInfo): boolean => w.workId === WORK_ID)) { workScheduler.stopWork(workInfo(), true); }
    await notificationManager.cancelAll();
  }
}
export async function notificationStatus(context: common.Context): Promise<string> {
  if (!await notificationsEnabled(context)) { return '已关闭'; }
  return await notificationManager.isNotificationEnabled() ? '已开启' : '系统通知权限未开启';
}
export async function openNotificationSettings(context: common.UIAbilityContext): Promise<void> {
  await notificationManager.openNotificationSettingsWithResult(context);
}
async function publishSummary(profile: ServerProfile, events: NoticeEvent[]): Promise<void> {
  const title = events.length === 1 ? '下载完成' : `${events.length} 项下载完成`;
  const names = events.map((event: NoticeEvent): string => event.name).join('；');
  const text = names.length > 120 ? names.slice(0, 119) + '…' : names;
  const agent = await wantAgent.getWantAgent({ wants: [{ bundleName: 'com.personal.qbitharmony', abilityName: 'EntryAbility',
    action: 'com.personal.qbitharmony.NOTIFICATION.' + profile.id,
    parameters: { notificationServerId: profile.id } }], requestCode: 2710,
    operationType: wantAgent.OperationType.START_ABILITY, wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG] });
  await notificationManager.publish({ id: 2710, label: profile.id, isAlertOnce: true,
    autoDeletedTime: Date.now() + 86400000, wantAgent: agent,
    content: { notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
      normal: { title: title, text: text, additionalText: profile.name } } });
}
export async function observeCompletions(context: common.Context, profile: ServerProfile, torrents: Torrent[], checkedAt: number): Promise<void> {
  if (!await notificationManager.isNotificationEnabled()) { return; }
  const db = await database(context);
  // SQLite locks cover both the UI and WorkScheduler extension process.
  const tx = await db.createTransaction({ transactionType: relationalStore.TransactionType.IMMEDIATE });
  let events: NoticeEvent[] = [];
  try {
    if (await value(tx, 'enabled') !== 'true') { await tx.commit(); return; }
    const key = JSON.stringify([profile.id, profile.url, profile.username]);
    const previous = await value(tx, key);
    const result = completionNotice(previous ? JSON.parse(previous) as NoticeState : emptyNotice(), torrents, checkedAt, Date.now());
    await tx.execute('INSERT OR REPLACE INTO notices(key,value) VALUES (?,?)', [key, JSON.stringify(result.state)]);
    // Claim before publishing: a crash may lose one summary, but never replays a backlog.
    await tx.commit(); events = result.events;
  } catch (error) { await tx.rollback(); throw error as Error; }
  if (events.length && await notificationsEnabled(context)) { await publishSummary(profile, events); }
}
