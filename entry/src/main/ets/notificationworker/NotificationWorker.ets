// SPDX-License-Identifier: GPL-3.0-only
import { workScheduler, WorkSchedulerExtensionAbility } from '@kit.BackgroundTasksKit';
import { ProfileStore } from '../services/ProfileStore';
import { NativeTransport } from '../services/NativeTransport';
import { QbitClient } from '../core/QbitClient';
import { notificationsEnabled, observeCompletions } from '../services/LocalNotifications';
import { hilog } from '@kit.PerformanceAnalysisKit';

export default class NotificationWorker extends WorkSchedulerExtensionAbility {
  private cancelled: boolean = false;
  onWorkStart(work: workScheduler.WorkInfo): void {
    this.cancelled = false;
    this.check(work).catch(() => { hilog.warn(0, 'LocalNotifications', 'Background check unavailable'); });
  }
  onWorkStop(work: workScheduler.WorkInfo): void { this.cancelled = true; }
  private async check(work: workScheduler.WorkInfo): Promise<void> {
    const deadline = Date.now() + 90000;
    try {
      if (!await notificationsEnabled(this.context)) { return; }
      const store = new ProfileStore();
      const profiles = await store.load(this.context);
      for (const profile of profiles) {
        if (this.cancelled || Date.now() >= deadline) { break; }
        if (!profile.remember && profile.username) { continue; }
        try {
          const password = profile.remember ? await store.password(profile.id) : '';
          const client = new QbitClient(profile, password, new NativeTransport(5));
          const checkedAt = Date.now();
          // torrents() renews authentication on HTTP 403; no version lookup or mutations needed.
          const torrents = await client.torrents();
          if (!this.cancelled) { await observeCompletions(this.context, profile, torrents, checkedAt); }
        } catch (error) { hilog.info(0, 'LocalNotifications', 'Server skipped: unavailable network or credentials'); }
      }
    } finally {
      hilog.info(0, 'LocalNotifications', 'Background check finished');
      try { workScheduler.stopWork(work, false); } catch (error) { /* Already stopped by system. */ }
    }
  }
}
