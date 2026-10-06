// SPDX-License-Identifier: GPL-3.0-only
import { FrameCallback, ColorMetrics, RectShape, SymbolGlyphModifier, TextModifier, LengthMetrics, ToolBar, ToolBarOptions, ToolBarModifier, DividerModifier, ItemState, ChipGroup, ChipSize, uiMaterial } from '@kit.ArkUI';
import { TitleBarStyleOptions, HideMode, HdsTitleBarContentStyle, DividerShowType, ScrollEffectType, hdsMaterial, HdsNavigation, HdsNavDestination, HdsNavigationTitleMode, HdsNavDestinationTitleMode, HdsTabs, HdsTabsController, HdsAnimationMode, HdsNavigationMenuItemOptions, HdsListItemCard, TextOptions, SuffixArrow, SuffixTextAndArrow, SuffixCustomBuilder } from '@kit.UIDesignKit';
import { TorrentRows, TorrentRowData } from '../services/TorrentRows';
import { TorrentCard } from './TorrentCard';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { systemShare } from '@kit.ShareKit';
import { FileNode, fileTree, toggleFileSelection } from '../core/FileTree';
import { IncomingShare } from '../services/ShareService';
import { TorrentProperties, TorrentPeer, AddOptions, AppSettings, Category, ServerProfile, Torrent, TorrentFile, Tracker, Transfer, Upload } from '../core/Models';
import { bytes, duration, FILTER_LABELS, isStopped, percent, selectTorrents, SORT_LABELS, stateLabel } from '../core/Format';
import { initialServer, serverAfterRemoval, upsertServer } from '../core/ServerSelection';
import { normalizeBaseUrl, QbitClient } from '../core/QbitClient';
import { NativeTransport } from '../services/NativeTransport';
import { ProfileStore } from '../services/ProfileStore';
import { notificationStatus, notificationsEnabled, setNotifications, openNotificationSettings, observeCompletions } from '../services/LocalNotifications';

interface DetailPair { label: string; value: string; last?: boolean; }
interface SettingsEntry { title: string; subtitle: string; route: string; }
interface ActionEntry { title: string; action: () => void; opensPage?: boolean; destructive?: boolean; }
interface SwitchEntry { title: string; checked: boolean; change: (checked: boolean) => void; }
interface ChoiceEntry { title: string; options: string[]; selected: number; value: string; change: (index: number) => void; }
interface InputEntry { title: string; subtitle?: string; value: string; placeholder?: string; type?: InputType; id?: string; maxLength?: number; change: (value: string) => void; }

class DetailLayoutReady extends FrameCallback {
  private action: () => void;
  constructor(action: () => void) { super(); this.action = action; }
  onIdle(_timeLeft: number): void { this.action(); }
}

@Observed
class TaskSummaryMotion {
  progress: number = 0;
}

@Observed
class DetailTabSelection {
  index: number = 0;
}

@Component
struct DetailTabStrip {
  @ObjectLink selection: DetailTabSelection;
  change: (index: number) => void = () => {};
  measure: () => void = () => {};
  build() {
    ChipGroup({ items: [{ label: { text: '概览' } }, { label: { text: '文件' } },
      { label: { text: 'Tracker' } }, { label: { text: '用户' } }],
      itemStyle: { size: ChipSize.SMALL, fontColor: $r('sys.color.font_secondary'),
        selectedFontColor: $r('sys.color.brand'), selectedBackgroundColor: $r('sys.color.comp_background_primary') },
      selectedIndexes: [this.selection.index], multiple: false,
      chipGroupSpace: { itemSpace: 8, startSpace: 16, endSpace: 16 },
      chipGroupPadding: { top: 6, bottom: 6 },
      backgroundSystemMaterial: new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
        materialColor: $r('sys.color.comp_background_tertiary') }),
      selectedBackgroundSystemMaterial: new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
        materialColor: $r('sys.color.comp_background_primary') }),
      onChange: (indexes: number[]) => { if (indexes.length && indexes[0] !== this.selection.index) { this.change(indexes[0]); } }
    }).id('detailTabStrip').width('100%').onAreaChange(() => { this.measure(); })
  }
}

@Component
struct TaskSummaryContent {
  @ObjectLink motion: TaskSummaryMotion;
  @Prop countText: string = '';
  @Prop speedText: string = '';
  build() {
    Row() {
      Text(this.countText).fontSize(12).fontColor($r('sys.color.font_secondary')).layoutWeight(1)
      if (this.speedText) {
        Text(this.speedText).fontSize(12).fontColor($r('sys.color.font_secondary'))
      }
    }.width('100%').height(40).padding({ left: 16, right: 16, bottom: 8 })
      // Soften the foreground before HDS clips it during the native collapse.
      .blur(8 * this.motion.progress)
      .opacity(Math.pow(1 - this.motion.progress, 2))
  }
}

@Component
export struct Home {
  @State summaryMotion: TaskSummaryMotion = new TaskSummaryMotion();
  @State notificationStatus: string = '已关闭';
  @State notificationEnabled: boolean = false;
  @State expandedFiles: string[] = [];
  @State selectedFiles: number[] = [];
  @State selectingFiles: boolean = false;
  @State bulkEditing: boolean = false;
  @State ruleRatio: string = '-2';
  @State ruleMinutes: string = '-2';
  @State ruleInactive: string = '-2';
  private profilesReady: boolean = false;
  @State searching: boolean = false;
  private taskRows: TorrentRows = new TorrentRows();
  private visible: Torrent[] = [];
  @State visibleCount: number = 0;
  private visibleUpdatePending: boolean = false;
  private tabsController: HdsTabsController = new HdsTabsController();
  @StorageLink('navigationBarHeightPx') private navigationBarHeightPx: number = 0;
  @StorageLink('statusBarHeightPx') private statusBarHeightPx: number = 0;
  private settingsScroller: Scroller = new Scroller();
  private pageScrollers: Map<string, Scroller> = new Map();
  @State detailTabSelection: DetailTabSelection = new DetailTabSelection();
  @State detailContentIndex: number = 0;
  @State detailHeaderBottom: number = 0;
  private detailScrollOffsets: number[] = [0, 0, 0, 0];
  private detailTabsController: TabsController = new TabsController();
  @State choiceRowWidth: number = 0;
  @State bulkToolItems: ToolBarOptions = new ToolBarOptions();
  private taskScroller: Scroller = new Scroller();
  private pendingConnectId: string = '';
  @State settings: AppSettings = { rememberServer: true, hideUrls: false, lastServerId: '', refreshSeconds: 5, timeoutSeconds: 10, theme: 0 };
  @State profiles: ServerProfile[] = [];
  @State @Watch('queueVisibleUpdate') torrents: Torrent[] = [];
  @State files: TorrentFile[] = [];
  @State trackers: Tracker[] = [];
  @State properties: TorrentProperties = {};
  @State peers: TorrentPeer[] = [];
  @State peerError: string = '';
  @State detailError: string = '';
  @State detailLoading: boolean = false;
  @State @Watch('queueVisibleUpdate') transfer: Transfer = { dl_info_speed: 0, up_info_speed: 0, dl_info_data: 0, up_info_data: 0,
    dl_rate_limit: 0, up_rate_limit: 0, connection_status: '' };
  @State connected: boolean = false;
  @State activeName: string = '';
  @State activeId: string = '';
  @State version: string = '';
  @State @Watch('updateBulkTools') busy: boolean = false;
  @State refreshing: boolean = false;
  @State refreshPullOffset: number = 0;
  @State taskListWidth: number = 0;
  @State taskListHeight: number = 0;
  @State taskScrolled: boolean = false;
  @State taskBlurProgress: number = 0;
  @State error: string = '';
  @State lastUpdate: string = '';
  @State tab: number = 0;
  @State @Watch('queueVisibleUpdate') query: string = '';
  @State @Watch('queueVisibleUpdate') filter: number = 0;
  @State @Watch('queueVisibleUpdate') sort: number = 1;
  @State @Watch('queueVisibleUpdate') reverseSort: boolean = false;
  @State categories: Category[] = [];
  @State tags: string[] = [];
  @State @Watch('queueVisibleUpdate') trackerMap: Record<string, string[]> = {};
  @State @Watch('queueVisibleUpdate') trackerFilter: string = '';
  @State @Watch('updateBulkTools') selection: string[] = [];
  @State @Watch('selectionModeChanged') selecting: boolean = false;
  @State addOptions: AddOptions = { tags: '', rename: '', sequential: false, firstLast: false, autoTmm: 0, downloadLimit: '', uploadLimit: '' };
  @State editValue: string = '';
  @State editAction: string = '';
  @State @Watch('queueVisibleUpdate') categoryFilter: string = '';
  @State @Watch('queueVisibleUpdate') tagFilter: string = '';
  @State selected: Torrent | undefined = undefined;
  @State editId: string = '';
  @State serverName: string = '';
  @State serverUrl: string = '';
  @State username: string = '';
  @State password: string = '';
  @State remember: boolean = true;
  @State links: string = '';
  @State savePath: string = '';
  @State addCategory: string = '';
  @State startStopped: boolean = false;
  @State uploadName: string = '';

  @State downloadLimit: string = '0';
  @State uploadLimit: string = '0';
  @State paths: NavPathStack = new NavPathStack();
  private store: ProfileStore = new ProfileStore();
  private client: QbitClient | undefined = undefined;
  private upload: Upload | undefined = undefined;
  private timer: number = -1;
  private generation: number = 0;
  private detailGeneration: number = 0;
  private pollBusy: boolean = false;
  private lastPoll: number = 0;
  private sessionPasswords: Map<string, string> = new Map();

  aboutToAppear(): void {
    this.bulkToolItems = this.bulkTools();
    this.loadProfiles();
    this.timer = setInterval(() => {
      this.consumeShare();
      this.consumeNotification();
      if (AppStorage.get<boolean>('foreground') !== false && this.connected && !this.busy && !this.pollBusy &&
        this.settings.refreshSeconds > 0 && Date.now() - this.lastPoll >= this.settings.refreshSeconds * 1000) {
        this.refresh(false);
      }
    }, 1000);
  }
  aboutToDisappear(): void {
    clearInterval(this.timer);
    this.generation++; this.detailGeneration++; this.client = undefined;
  }
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private pageScroller(name: string): Scroller {
    let scroller = this.pageScrollers.get(name);
    if (!scroller) { scroller = new Scroller(); this.pageScrollers.set(name, scroller); }
    return scroller;
  }
  private navigationStyle(taskRoot: boolean = false, detailTitle: boolean = false): TitleBarStyleOptions {
    const backdrop = ColorMetrics.resourceColor($r('sys.color.comp_background_gray'));
    const taskBackground = ColorMetrics.rgba(backdrop.red, backdrop.green, backdrop.blue,
      backdrop.alpha / 255 * this.taskBlurProgress).color;
    const content: HdsTitleBarContentStyle = {
      titleStyle: { mainTitleColor: $r('sys.color.font_primary'), subTitleColor: $r('sys.color.font_secondary') },
      menuStyle: { iconColor: $r('sys.color.icon_primary'), textColor: $r('sys.color.font_primary') },
      backIconStyle: { iconColor: $r('sys.color.icon_primary') }
    };
    return {
      systemMaterialEffect: { materialType: hdsMaterial.MaterialType.ADAPTIVE, materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE },
      scrollEffectOpts: { enableScrollEffect: !taskRoot, scrollEffectType: ScrollEffectType.GRADIENT_BLUR,
        enableRefreshOffsetChange: false, blurEffectiveStartOffset: LengthMetrics.vp(0), blurEffectiveEndOffset: LengthMetrics.vp(detailTitle ? 24 : 8) },
      originalStyle: { backgroundStyle: { backgroundColor: taskRoot ? taskBackground : Color.Transparent,
        blurRadius: taskRoot ? 12 * this.taskBlurProgress : 0, maskExtraHeight: 32 }, contentStyle: content },
      scrollEffectStyle: { backgroundStyle: { backgroundColor: taskRoot ? $r('sys.color.comp_background_gray') : Color.Transparent,
        blurRadius: 12, maskExtraHeight: 32 }, contentStyle: content }
    };
  }
  private message(error: Error): string { return error.message || '操作失败，请稍后重试。'; }
  private async loadProfiles(): Promise<void> {
    try {
      this.notificationStatus = await notificationStatus(this.context()).catch((): string => '通知状态读取失败');
      this.notificationEnabled = await notificationsEnabled(this.context()).catch((): boolean => false);
      this.settings = await this.store.loadSettings(this.context());
      this.sort = this.settings.sort === undefined ? 1 : this.settings.sort;
      this.reverseSort = this.settings.reverseSort || false;
      this.applyTheme();
      this.profiles = await this.store.load(this.context());
      const initial = initialServer(this.profiles, this.settings.lastServerId, this.settings.rememberServer);
      if (initial) { await this.connectSaved(initial); }
    }
    catch (error) { this.error = '无法读取服务器配置。'; }
    finally { this.profilesReady = true; this.consumeShare(); }
  }
  private toast(message: string): void {
    try { this.getUIContext().getPromptAction().showToast({ message: message }); } catch (error) { this.error = message; }
  }
  private applyTheme(): void {
    try {
      this.context().getApplicationContext().setColorMode(this.settings.theme === 1 ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT :
        this.settings.theme === 2 ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (error) { this.error = '无法应用颜色模式。'; }
  }
  private async saveSettings(): Promise<void> {
    try { await this.store.saveSettings(this.context(), this.settings); this.applyTheme(); }
    catch (error) { this.error = this.message(error); }
  }
  private async testServer(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    try {
      const profile: ServerProfile = { id: '', name: this.serverName, url: this.serverUrl, username: this.username, remember: false };
      const client = new QbitClient(profile, this.password, new NativeTransport(this.settings.timeoutSeconds));
      const version = await client.connect(); this.toast('连接成功：qBittorrent ' + version); this.error = '';
    } catch (error) { this.error = this.message(error); }
    finally { this.busy = false; }
  }
  private async configureNotifications(action: string): Promise<void> {
    if (this.busy) { return; }
    this.busy = true; this.error = '';
    try {
      if (action === 'enable' || action === 'disable') { await setNotifications(this.context(), action === 'enable'); }
      else if (action === 'settings') { await openNotificationSettings(this.context()); }
      this.notificationStatus = await notificationStatus(this.context());
      this.notificationEnabled = await notificationsEnabled(this.context());
      if (action === 'enable' && this.connected) {
        const profile = this.profiles.find((p: ServerProfile): boolean => p.id === this.activeId);
        if (profile) { await observeCompletions(this.context(), profile, this.torrents, Date.now()); }
      }
    } catch (error) { this.error = this.message(error); }
    finally { this.busy = false; }
  }
  private async consumeNotification(): Promise<void> {
    if (!this.profilesReady || this.busy) { return; }
    const id = AppStorage.get<string>('notificationServerId');
    if (!id) { return; }
    AppStorage.delete('notificationServerId');
    const profile = this.profiles.find((p: ServerProfile): boolean => p.id === id);
    if (!profile) { this.toast('通知对应的服务器已移除'); return; }
    if (this.activeId !== id || !this.connected) { await this.connectSaved(profile); }
    else { this.paths.clear(); this.tab = 0; await this.refresh(true); }
  }
  private disconnect(resetNavigation: boolean = true): void {
    this.generation++; this.detailGeneration++; this.client = undefined; this.connected = false;
    this.activeId = ''; this.activeName = ''; this.version = ''; this.torrents = [];
    this.selected = undefined; this.files = []; this.trackers = []; this.properties = {}; this.peers = []; this.peerError = ''; this.detailError = ''; this.lastUpdate = ''; this.error = '';
    this.query = ''; this.categoryFilter = ''; this.tagFilter = ''; this.trackerFilter = ''; this.filter = 0;
    this.categories = []; this.tags = []; this.trackerMap = {}; this.selecting = false; this.selection = [];
    if (resetNavigation) { this.paths.clear(); }
  }
  private async connect(profile: ServerProfile, password: string, navigate: boolean = true): Promise<void> {
    this.disconnect(navigate);
    const generation = this.generation;
    this.activeName = profile.name; this.activeId = profile.id;
    if (navigate) { this.tab = 0; }
    const client = new QbitClient(profile, password, new NativeTransport(this.settings.timeoutSeconds));
    this.busy = true;
    try {
      this.settings.lastServerId = profile.id;
      await this.saveSettings();
      const version = await client.connect();
      if (generation !== this.generation) { return; }
      this.client = client; this.version = version; this.activeName = profile.name;
      this.activeId = profile.id; await this.refresh(false); if (generation === this.generation && !this.error) { this.connected = true; }
    } catch (error) { if (generation === this.generation) { this.error = this.message(error); } }
    finally { this.busy = false; }
  }
  private async connectSaved(profile: ServerProfile, navigate: boolean = true): Promise<void> {
    if (this.busy) { return; }
    if (!profile.remember && profile.username && !this.sessionPasswords.has(profile.id)) {
      this.pendingConnectId = profile.id; await this.editServer(profile); return;
    }
    this.busy = true;
    try { await this.connect(profile, profile.remember ? await this.store.password(profile.id) : this.sessionPasswords.get(profile.id) || '', navigate); }
    catch (error) { this.error = '无法读取已保存的密码，请编辑服务器后重新输入。'; }
    finally { this.busy = false; }
  }
  private async refresh(showSpinner: boolean): Promise<void> {
    const client = this.client;
    if (!client || this.pollBusy) { return; }
    const generation = this.generation;
    this.pollBusy = true; this.refreshing = showSpinner; this.lastPoll = Date.now();
    const checkedAt = this.lastPoll;
    try {
      const snapshot = await client.sync();
      if (generation !== this.generation) { return; }
      const torrents = snapshot.torrents;
      this.torrents = torrents; this.transfer = snapshot.transfer;
      this.categories = snapshot.categories; this.tags = snapshot.tags; this.trackerMap = snapshot.trackers;
      this.selection = this.selection.filter((hash: string) => torrents.some((t: Torrent) => t.hash === hash));
      if (this.selected) {
        const hash = this.selected.hash;
        this.selected = torrents.find((t: Torrent) => t.hash === hash);
      }
      this.lastUpdate = new Date().toLocaleTimeString(); this.error = '';
      const profile = this.profiles.find((p: ServerProfile): boolean => p.id === this.activeId);
      if (profile && this.notificationEnabled) {
        await observeCompletions(this.context(), profile, torrents, checkedAt).catch(() => { this.notificationStatus = '通知检查失败，请稍后重试'; });
      }
      if (this.selected && this.paths.getAllPathName().includes('detail')) { await this.loadLiveDetails(this.selected.hash); }
    } catch (error) { if (generation === this.generation) { this.error = this.message(error); } }
    finally { this.pollBusy = false; this.refreshing = false; }
  }
  private newServer(): void {
    this.pendingConnectId = '';
    this.editId = ''; this.serverName = ''; this.serverUrl = ''; this.username = ''; this.password = '';
    this.remember = true; this.error = ''; this.paths.pushPathByName('server', null);
  }
  private async editServer(profile: ServerProfile): Promise<void> {
    this.editId = profile.id; this.serverName = profile.name; this.serverUrl = profile.url;
    this.username = profile.username; this.remember = profile.remember; this.password = this.sessionPasswords.get(profile.id) || ''; this.error = '';
    if (profile.remember) {
      try { this.password = await this.store.password(profile.id); }
      catch (error) { this.error = '请重新输入密码。'; }
    }
    this.paths.pushPathByName('server', null);
  }
  private async saveServer(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    try {
      if (!this.serverName.trim()) { throw new Error('请填写服务器名称。'); }
      const profile: ServerProfile = {
        id: this.editId || String(Date.now()), name: this.serverName.trim(),
        url: normalizeBaseUrl(this.serverUrl), username: this.username.trim(), remember: this.remember && this.password.length > 0
      };
      if (profile.remember) { await this.store.putPassword(profile.id, this.password); }
      else if (this.editId && this.profiles.some((p: ServerProfile) => p.id === this.editId && p.remember)) {
        await this.store.removePassword(profile.id);
      }
      const shouldReconnect = this.profiles.length === 0 || profile.id === this.activeId || profile.id === this.pendingConnectId;
      this.pendingConnectId = '';
      const updated = upsertServer(this.profiles, profile);
      await this.store.save(this.context(), updated); this.profiles = updated;
      const password = this.password; this.password = '';
      this.sessionPasswords.set(profile.id, password);
      this.paths.pop(); this.toast('服务器配置已保存');
      if (shouldReconnect) { await this.connect(profile, password, false); }
    } catch (error) { this.error = this.message(error); }
    finally { this.busy = false; }
  }
  private forgetServer(profile: ServerProfile): void {
    this.getUIContext().showAlertDialog({ title: '删除服务器配置？', message: `仅移除“${profile.name}”的本机配置，不影响服务器任务。`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '删除配置', fontColor: $r('sys.color.warning'), action: () => { this.removeProfile(profile); } }
    });
  }
  private async removeProfile(profile: ServerProfile): Promise<void> {
    this.busy = true;
    try {
      if (profile.remember) { await this.store.removePassword(profile.id); }
      const nextServer = serverAfterRemoval(this.profiles, profile.id, this.activeId);
      const updated = this.profiles.filter((p: ServerProfile) => p.id !== profile.id);
      await this.store.save(this.context(), updated); this.profiles = updated;
      this.sessionPasswords.delete(profile.id);
      if (this.editId === profile.id) { this.editId = ''; this.paths.pop(); }
      if (profile.id === this.activeId) {
        this.disconnect(false); this.busy = false;
        if (nextServer) { await this.connectSaved(nextServer, false); }
      }
    } catch (error) { this.error = '删除配置失败，请重试。'; }
    finally { this.busy = false; }
  }
  private async operate(action: string, hashes: string[]): Promise<void> {
    const client = this.client;
    if (!client || this.busy) { return; }
    this.busy = true;
    try { await client.action(action, hashes); this.toast('操作已提交'); await this.refresh(true); }
    catch (error) { this.error = this.message(error); }
    finally { this.busy = false; }
  }
  private async openDetails(torrent: Torrent): Promise<void> {
    if (this.selected?.hash !== torrent.hash) {
      this.detailTabSelection.index = 0;
      this.detailContentIndex = 0;
      this.detailHeaderBottom = 0;
      this.detailScrollOffsets = [0, 0, 0, 0];
      this.detailTabsController = new TabsController();
      for (let index = 0; index < 4; index++) { this.pageScrollers.delete('detail-' + index); }
    }
    this.expandedFiles = []; this.selectedFiles = []; this.selectingFiles = false;
    this.selected = torrent; this.files = []; this.trackers = [];
    this.paths.pushPathByName('detail', null); await this.loadLiveDetails(torrent.hash); await this.loadDetails(torrent.hash);
  }
  private async loadLiveDetails(hash: string): Promise<void> {
    const client = this.client;
    if (!client || this.detailLoading) { return; }
    const generation = this.generation;
    this.detailLoading = true;
    try {
      try {
        const properties = await client.properties(hash);
        if (generation === this.generation && this.selected?.hash === hash) { this.properties = properties; this.detailError = ''; }
      } catch (error) { if (generation === this.generation && this.selected?.hash === hash) { this.detailError = this.message(error); } }
      try {
        const peers = await client.peers(hash);
        if (generation === this.generation && this.selected?.hash === hash) { this.peers = peers; this.peerError = ''; }
      } catch (error) { if (generation === this.generation && this.selected?.hash === hash) { this.peerError = this.message(error); } }
    } finally { this.detailLoading = false; }
  }
  private dateText(value?: number): string { return value && value > 0 ? new Date(value * 1000).toLocaleString('zh-CN', { hourCycle: 'h23' }) : '—'; }
  private amountText(value?: number): string { return value === undefined || value < 0 ? '—' : bytes(value); }
  private elapsedText(value?: number): string {
    if (value === undefined || value < 0) { return '—'; }
    return Math.floor(value / 86400) + ' 天 ' + Math.floor(value % 86400 / 3600) + ' 小时 ' + Math.floor(value % 3600 / 60) + ' 分钟';
  }
  private async loadDetails(hash: string): Promise<void> {
    const client = this.client;
    if (!client) { return; }
    const generation = ++this.detailGeneration;
    try {
      const files = await client.files(hash); const trackers = await client.trackers(hash);
      if (generation !== this.detailGeneration || this.selected?.hash !== hash) { return; }
      this.files = files; this.trackers = trackers;
    } catch (error) { if (generation === this.detailGeneration) { this.error = this.message(error); } }
  }
  private confirmDelete(torrent: Torrent, deleteFiles: boolean): void {
    this.getUIContext().showAlertDialog({
      title: deleteFiles ? '删除任务和下载文件？' : '仅移除任务？',
      message: deleteFiles ? `“${torrent.name}”在服务器上的下载文件也会被永久删除。` : `移除“${torrent.name}”，保留服务器上的下载文件。`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: deleteFiles ? '永久删除' : '仅移除任务', fontColor: $r('sys.color.warning'),
        action: () => { this.deleteTorrent(torrent.hash, deleteFiles); } }
    });
  }
  private async deleteTorrent(hash: string, deleteFiles: boolean): Promise<void> {
    const client = this.client;
    if (!client || this.busy) { return; }
    this.busy = true;
    try { await client.remove(hash, deleteFiles); this.paths.pop(); this.selected = undefined; await this.refresh(true); }
    catch (error) { this.error = this.message(error); }
    finally { this.busy = false; }
  }
  private beginAdd(): void {
    this.links = ''; this.savePath = ''; this.addCategory = ''; this.startStopped = false;
    this.upload = undefined; this.uploadName = ''; this.paths.pushPathByName('add', null);
    this.addOptions = { tags: '', rename: '', sequential: false, firstLast: false, autoTmm: 0, downloadLimit: '', uploadLimit: '' };
  }
  private async pickTorrent(): Promise<void> {
    try {
      const view = new picker.DocumentViewPicker(this.context());
      const uris = await view.select({ maxSelectNumber: 1, fileSuffixFilters: ['种子文件|.torrent'] });
      if (!uris.length) { return; }
      const file = await fileIo.open(uris[0], fileIo.OpenMode.READ_ONLY);
      try {
        const stat = await fileIo.stat(file.fd);
        if (stat.size <= 0 || stat.size > 10 * 1024 * 1024) { throw new Error('请选择小于 10 MiB 的有效种子文件。'); }
        const data = new ArrayBuffer(stat.size);
        const read = await fileIo.read(file.fd, data);
        if (read !== stat.size) { throw new Error('种子文件读取不完整，请重试。'); }
        this.upload = { name: 'upload.torrent', data: data }; this.uploadName = `已选择种子文件 · ${bytes(stat.size)}`;
      } finally { await fileIo.close(file); }
    } catch (error) { this.error = this.message(error); }
  }
  private async addTorrent(): Promise<void> {
    const client = this.client;
    if (!client || this.busy) { return; }
    this.busy = true;
    try {
      await client.add(this.links, this.savePath, this.addCategory, this.startStopped, this.upload, this.addOptions);
      this.upload = undefined; this.uploadName = ''; this.paths.pop(); this.toast('任务已提交'); await this.refresh(true);
    } catch (error) { this.error = this.message(error); }
    finally { this.busy = false; }
  }
  private async changePriority(file: TorrentFile, priority: number): Promise<void> {
    const client = this.client; const hash = this.selected?.hash;
    if (!client || !hash || this.busy) { return; }
    this.busy = true;
    try { await client.setFilePriority(hash, file.index, priority); await this.loadDetails(hash); }
    catch (error) { this.error = this.message(error); }
    finally { this.busy = false; }
  }
  private async setLimit(direction: string, value: string): Promise<void> {
    const client = this.client;
    if (!client || this.busy) { return; }
    this.busy = true;
    try { await client.setLimit(direction, value); this.toast('限速已更新'); await this.refresh(true); }
    catch (error) { this.error = this.message(error); }
    finally { this.busy = false; }
  }
  private visibleTorrents(): Torrent[] {
    return this.visible;
  }
  private queueVisibleUpdate(): void {
    if (this.visibleUpdatePending) { return; }
    this.visibleUpdatePending = true;
    Promise.resolve().then(() => {
      this.visibleUpdatePending = false;
      this.visible = selectTorrents(this.torrents, this.query, this.filter, this.sort, this.categoryFilter, this.tagFilter,
        this.reverseSort, this.transfer.use_subcategories || false, this.trackerFilter, this.trackerMap);
      this.taskRows.update(this.visible);
      this.visibleCount = this.visible.length;
    });
  }
  private selectionModeChanged(): void {
    if (this.selecting) { this.tabsController.applyHideAnimation(HdsAnimationMode.CLICK_ANIMATION); }
    else { this.tabsController.applyShowAnimation(HdsAnimationMode.CLICK_ANIMATION); }
  }
  private toggleSelection(hash: string): void {
    this.selection = this.selection.includes(hash) ? this.selection.filter((id: string) => id !== hash) : this.selection.concat([hash]);
  }
  private async saveSort(): Promise<void> {
    this.settings.sort = this.sort; this.settings.reverseSort = this.reverseSort; await this.saveSettings();
  }
  private confirmBulkDelete(): void {
    const hashes = this.selection.slice();
    this.getUIContext().showAlertDialog({ title: `移除 ${hashes.length} 个任务？`, message: '保留服务器上的全部下载文件。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '移除任务', fontColor: $r('sys.color.warning'), action: () => { this.bulkDelete(hashes); } }
    });
  }
  private async bulkDelete(hashes: string[]): Promise<void> {
    const client = this.client;
    if (!client || this.busy) { return; }
    this.busy = true;
    try { await client.removeMany(hashes, false); this.selection = []; this.selecting = false; await this.refresh(true); }
    catch (error) { this.error = this.message(error); }
    finally { this.busy = false; }
  }
  private openEdit(action: string, bulk: boolean = false): void {
    this.bulkEditing = bulk;
    this.editAction = action;
    this.editValue = bulk ? '' : action === 'rename' ? this.selected?.name || '' : action === 'location' ? this.selected?.save_path || '' : action === 'category' ? this.selected?.category || '' : '';
    this.paths.pushPathByName('editTorrent', null);
  }
  private async applyTorrentEdit(): Promise<void> {
    const client = this.client; const torrent = this.selected;
    if (!client || (!torrent && !this.bulkEditing) || this.busy) { return; }
    const hashes = this.bulkEditing ? this.selection.join('|') : torrent!.hash;
    if (!hashes) { return; }
    this.busy = true;
    try {
      if (this.editAction === 'rename') { await client.rename(hashes, this.editValue); }
      else if (this.editAction === 'location') { await client.setLocation(hashes, this.editValue); }
      else if (this.editAction === 'category') { await client.setCategory(hashes, this.editValue.trim()); }
      else { await client.tags(hashes, this.editValue, this.editAction === 'removeTags'); }
      this.paths.pop(); this.toast('操作已提交'); await this.refresh(true);
    } catch (error) { this.error = this.message(error); }
    finally { this.busy = false; }
  }
  private async toggleForce(torrent: Torrent): Promise<void> {
    const client = this.client;
    if (!client || this.busy) { return; }
    this.busy = true;
    try { await client.forceStart(torrent.hash, !torrent.force_start); await this.refresh(true); }
    catch (error) { this.error = this.message(error); }
    finally { this.busy = false; }
  }

  private consumeShare(): void {
    if (!this.profilesReady || this.busy) { return; }
    const incoming = AppStorage.get<IncomingShare>('incomingShare');
    if (!incoming) { return; }
    AppStorage.delete('incomingShare');
    if (incoming.error) { this.error = incoming.error; return; }
    if (this.paths.getAllPathName().includes('add')) {
      this.getUIContext().showAlertDialog({ title: '替换当前添加内容？', message: '收到新的分享内容，当前尚未提交的表单将被替换。',
        primaryButton: { value: '保留当前', action: () => {} },
        secondaryButton: { value: '使用分享内容', action: () => { this.applyShare(incoming); } } });
    } else { this.applyShare(incoming); }
  }
  private applyShare(incoming: IncomingShare): void {
    this.paths.clear(); this.tab = 0; this.beginAdd();
    this.links = incoming.links; this.upload = incoming.upload;
    this.uploadName = incoming.upload ? '分享的种子文件 · ' + bytes(incoming.upload.data.byteLength) : '';
    if (!this.connected) { this.error = '请先连接服务器，分享内容已保留。'; }
  }
  private fileNodes(): FileNode[] { return fileTree(this.files, this.expandedFiles); }
  private toggleFolder(node: FileNode): void {
    this.expandedFiles = this.expandedFiles.includes(node.path) ? this.expandedFiles.filter((p: string): boolean => p !== node.path) : this.expandedFiles.concat(node.path);
  }
  private chooseFilePriority(ids: number[]): void {
    this.getUIContext().showActionSheet({ title: `设置 ${ids.length} 个文件的优先级`, message: '', sheets: [
      { title: '不下载', action: () => { this.applyFilePriority(ids, 0); } },
      { title: '普通', action: () => { this.applyFilePriority(ids, 1); } },
      { title: '高', action: () => { this.applyFilePriority(ids, 6); } },
      { title: '最高', action: () => { this.applyFilePriority(ids, 7); } }
    ] });
  }
  private async applyFilePriority(ids: number[], priority: number): Promise<void> {
    const client = this.client; const hash = this.selected?.hash;
    if (!client || !hash || this.busy) { return; }
    this.busy = true;
    try { await client.setFilePriorities(hash, ids, priority); await this.loadDetails(hash); this.toast('文件优先级已更新'); }
    catch (error) { this.error = this.message(error); }
    finally { this.busy = false; }
  }
  private openTaskRules(): void {
    const torrent = this.selected; if (!torrent) { return; }
    this.downloadLimit = String(Math.ceil(Math.max(0, torrent.dl_limit || 0) / 1024));
    this.uploadLimit = String(Math.ceil(Math.max(0, torrent.up_limit || 0) / 1024));
    this.ruleRatio = String(torrent.ratio_limit ?? -2);
    this.ruleMinutes = String(torrent.seeding_time_limit ?? -2);
    this.ruleInactive = String(torrent.inactive_seeding_time_limit ?? -2);
    this.paths.pushPathByName('taskRules', null);
  }
  private async saveTaskLimit(direction: string, limit: string): Promise<void> {
    const client = this.client; const hash = this.selected?.hash;
    if (!client || !hash || this.busy) { return; }
    this.busy = true;
    try { await client.setTorrentLimit(hash, direction, limit); this.toast('任务限速已保存'); await this.refresh(false); }
    catch (error) { this.error = this.message(error); }
    finally { this.busy = false; }
  }
  private async saveTaskRules(): Promise<void> {
    const client = this.client; const hash = this.selected?.hash;
    if (!client || !hash || this.busy) { return; }
    this.busy = true;
    try { await client.setShareLimits(hash, this.ruleRatio, this.ruleMinutes, this.ruleInactive); this.toast('做种规则已保存'); await this.refresh(false); }
    catch (error) { this.error = this.message(error); }
    finally { this.busy = false; }
  }
  private async shareMagnet(): Promise<void> {
    const torrent = this.selected; if (!torrent || this.busy) { return; }
    try {
      const magnet = torrent.magnet_uri;
      if (!magnet) { throw new Error('服务器尚未提供此任务的磁力链接。'); }
      const controller = new systemShare.ShareController(new systemShare.SharedData({
        utd: 'general.plain-text', content: magnet, title: torrent.name
      }));
      await controller.show(this.context(), { selectionMode: systemShare.SelectionMode.SINGLE, previewMode: systemShare.SharePreviewMode.DETAIL });
    } catch (error) { this.error = this.message(error); }
  }
  private async exportSelected(): Promise<void> {
    const client = this.client; const torrent = this.selected;
    if (!client || !torrent || this.busy) { return; }
    this.busy = true;
    try {
      const data = await client.exportTorrent(torrent.hash);
      const name = torrent.name.replace(/[\\/:*?"<>|\r\n]/g, '_').slice(0, 120) + '.torrent';
      const uris = await new picker.DocumentViewPicker(this.context()).save({ newFileNames: [name], fileSuffixChoices: ['种子文件|.torrent'] });
      if (!uris.length) { return; }
      const file = await fileIo.open(uris[0], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try {
        const written = await fileIo.write(file.fd, data);
        if (written !== data.byteLength) { throw new Error('文件未完整写入，请重新导出。'); }
      } finally { await fileIo.close(file); }
      this.toast('种子文件已导出');
    } catch (error) { this.error = this.message(error); }
    finally { this.busy = false; }
  }

  @Builder
  private taskRulesForm() {
    Column({ space: 12 }) {
      this.notice()
      Column() {
        this.inputRow({ title: '下载限速', subtitle: 'KiB/s，0 为不限速', value: this.downloadLimit, type: InputType.Number, change: (v: string) => { this.downloadLimit = v; } })
        this.cardDivider()
        this.actionRow({ title: '保存下载限速', action: () => { this.saveTaskLimit('Download', this.downloadLimit); } })
      }.groupedCard()
      Column() {
        this.inputRow({ title: '上传限速', subtitle: 'KiB/s，0 为不限速', value: this.uploadLimit, type: InputType.Number, change: (v: string) => { this.uploadLimit = v; } })
        this.cardDivider()
        this.actionRow({ title: '保存上传限速', action: () => { this.saveTaskLimit('Upload', this.uploadLimit); } })
      }.groupedCard()
      this.sectionTitle('做种规则')
      Column() {
        this.choiceRow({ title: '分享率上限', options: ['使用全局规则', '无限制', '自定义'],
          selected: this.ruleRatio === '-2' ? 0 : this.ruleRatio === '-1' ? 1 : 2,
          value: this.ruleRatio === '-2' ? '使用全局规则' : this.ruleRatio === '-1' ? '无限制' : '自定义',
          change: (i: number) => { this.ruleRatio = i === 0 ? '-2' : i === 1 ? '-1' : '1'; } })
        // 输入中的小数可能暂时不是有效数值，不能因此销毁自定义输入框。
        if (this.ruleRatio !== '-2' && this.ruleRatio !== '-1') {
          this.inputRow({ title: '分享率', value: this.ruleRatio, type: InputType.NUMBER_DECIMAL, change: (v: string) => { this.ruleRatio = v; } })
        }
        this.cardDivider()
        this.choiceRow({ title: '做种时间上限', options: ['使用全局规则', '无限制', '自定义'],
          selected: this.ruleMinutes === '-2' ? 0 : this.ruleMinutes === '-1' ? 1 : 2,
          value: this.ruleMinutes === '-2' ? '使用全局规则' : this.ruleMinutes === '-1' ? '无限制' : '自定义',
          change: (i: number) => { this.ruleMinutes = i === 0 ? '-2' : i === 1 ? '-1' : '1440'; } })
        if (this.ruleMinutes !== '-2' && this.ruleMinutes !== '-1') {
          this.inputRow({ title: '做种时间', subtitle: '分钟', value: this.ruleMinutes, type: InputType.Number, change: (v: string) => { this.ruleMinutes = v; } })
        }
        this.cardDivider()
        this.choiceRow({ title: '无活动做种上限', options: ['使用全局规则', '无限制', '自定义'],
          selected: this.ruleInactive === '-2' ? 0 : this.ruleInactive === '-1' ? 1 : 2,
          value: this.ruleInactive === '-2' ? '使用全局规则' : this.ruleInactive === '-1' ? '无限制' : '自定义',
          change: (i: number) => { this.ruleInactive = i === 0 ? '-2' : i === 1 ? '-1' : '60'; } })
        if (this.ruleInactive !== '-2' && this.ruleInactive !== '-1') {
          this.inputRow({ title: '无活动做种时间', subtitle: '分钟', value: this.ruleInactive, type: InputType.Number, change: (v: string) => { this.ruleInactive = v; } })
        }
      }.groupedCard()
      Button('保存做种规则').width('100%').onClick(() => { this.saveTaskRules(); })
    }.padding({ left: 16, right: 16, top: 12, bottom: 24 }).width('100%').enabled(!this.busy)
  }

  @Builder
  private filesPage() {
    List({ scroller: this.pageScroller('detail-1') }) {
      this.detailListInset()
      if (this.error) { ListItem() { this.notice() }.padding({ left: 16, right: 16 }) }
      ListItem() {
      Row({ space: 8 }) {
        Text(this.selectingFiles ? `已选 ${this.selectedFiles.length} 个文件` : `${this.files.length} 个文件`).fontSize(12).fontColor($r('sys.color.font_secondary')).layoutWeight(1)
        if (this.selectingFiles) {
          Button('全选').fontSize(14).fontWeight(FontWeight.Regular).padding({ left: 8, right: 8 }).backgroundColor(Color.Transparent).fontColor($r('sys.color.brand')).onClick(() => { this.selectedFiles = this.files.map((f: TorrentFile): number => f.index); })
          Button('优先级').enabled(this.selectedFiles.length > 0 && !this.busy).fontSize(14).fontWeight(FontWeight.Regular).padding({ left: 8, right: 8 }).backgroundColor(Color.Transparent).fontColor($r('sys.color.brand')).onClick(() => { this.chooseFilePriority(this.selectedFiles.slice()); })
        } else {
          Button('刷新').fontSize(14).fontWeight(FontWeight.Regular).padding({ left: 8, right: 8 }).backgroundColor(Color.Transparent).fontColor($r('sys.color.brand')).onClick(() => { if (this.selected) { this.loadDetails(this.selected.hash); } })
        }
        Button(this.selectingFiles ? '完成' : '选择').fontSize(14).fontWeight(FontWeight.Regular).padding({ left: 8, right: 8 }).backgroundColor(Color.Transparent).fontColor($r('sys.color.brand')).onClick(() => { this.selectingFiles = !this.selectingFiles; this.selectedFiles = []; })
      }.width('100%').height(40).padding({ left: 32, right: 32 })
      }
        if (this.files.length === 0) {
          ListItem() { this.empty(this.detailLoading ? '正在加载文件…' : '暂无文件', '') }
        }
        ListItemGroup() {
        ForEach(this.fileNodes(), (node: FileNode) => {
          ListItem() {
            Row({ space: 8 }) {
              if (this.selectingFiles) {
                Checkbox().select(node.ids.every((id: number): boolean => this.selectedFiles.includes(id)))
                  .onChange((checked: boolean) => {
                    const all = node.ids.every((id: number): boolean => this.selectedFiles.includes(id));
                    if (checked !== all) { this.selectedFiles = toggleFileSelection(this.selectedFiles, node.ids); }
                  })
              }
              if (node.directory) {
                SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).rotate({ angle: this.expandedFiles.includes(node.path) ? 90 : 0 }).fontColor([$r('sys.color.icon_secondary')])
              }
              Column({ space: 5 }) {
                Text(node.name).fontSize(16).fontColor($r('sys.color.font_primary')).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                Text(`${bytes(node.size)} · ${percent(node.progress)}%` + (node.directory ? ` · ${node.ids.length} 个文件` : '')).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
                if (this.selectingFiles && node.directory && node.ids.some((id: number): boolean => this.selectedFiles.includes(id))) {
                  Text(`已选 ${node.ids.filter((id: number): boolean => this.selectedFiles.includes(id)).length} / ${node.ids.length}`).fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
                }
              }.layoutWeight(1)
              if (!this.selectingFiles) {
                Button(node.priority === -1 ? '混合' : node.priority === 0 ? '不下载' : node.priority === 6 ? '高' : node.priority === 7 ? '最高' : '普通')
                  .fontSize(12).fontSize(14).fontWeight(FontWeight.Regular).padding({ left: 8, right: 8 }).backgroundColor(Color.Transparent).fontColor($r('sys.color.font_secondary')).enabled(!this.busy)
                  .onClick(() => { this.chooseFilePriority(node.ids); })
              }
            }.padding({ left: 16 + Math.min(node.depth, 5) * 12, right: 16, top: 12, bottom: 12 }).width('100%')
              .onClick(() => { if (node.directory) { this.toggleFolder(node); } else if (this.selectingFiles) { this.selectedFiles = toggleFileSelection(this.selectedFiles, node.ids); } else { this.chooseFilePriority(node.ids); } })
          }
        }, (node: FileNode): string => JSON.stringify(node))
        }.groupedCard().width('calc(100% - 32vp)').margin({ left: 16, right: 16 })
          .divider({ strokeWidth: 0.5, color: $r('sys.color.comp_divider'), startMargin: 16, endMargin: 16 })
    }.height('100%').width('100%').contentEndOffset(24).clipContent(ContentClipMode.SAFE_AREA)
      .scrollBarMargin({ start: LengthMetrics.vp(this.detailContentInset()), end: LengthMetrics.vp(24) })
      .onDidScroll(() => { this.updateDetailHeaderBounds(); }).onScrollStop(() => { this.updateDetailHeaderBounds(); })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  @Builder
  private notice() {
    if (this.error) {
      Row({ space: 8 }) {
        Text(this.error).fontSize(14).fontColor($r('sys.color.warning')).layoutWeight(1)
        Button('关闭').type(ButtonType.Normal).backgroundColor(Color.Transparent).fontColor($r('sys.color.warning'))
          .onClick(() => { this.error = ''; })
      }.padding(12).width('100%').backgroundColor($r('sys.color.comp_background_primary')).borderRadius(16)
    }
  }
  @Builder
  private label(text: string) { Text(text).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%') }
  @Builder
  private pair($$: DetailPair) {
    Row({ space: 12 }) {
      Text($$.label).fontSize(16).fontColor($r('sys.color.font_primary')).width('38%')
      Text($$.value).fontSize(14).fontColor($r('sys.color.font_secondary')).layoutWeight(1).textAlign(TextAlign.End).copyOption(CopyOptions.LocalDevice)
    }.width('100%').constraintSize({ minHeight: 48 }).padding({ left: 16, right: 16, top: 12, bottom: 12 })
    if (!$$.last) { this.cardDivider() }
  }
  @Styles
  private groupedCard() {
    .width('100%').backgroundColor($r('sys.color.comp_background_primary')).borderRadius(20).clip(true)
  }
  @Styles
  private secondaryScroll() {
    .width('100%').height('100%').align(Alignment.TopStart).clip(false)
  }
  @Builder
  private cardDivider() {
    Divider().strokeWidth(0.5).color($r('sys.color.comp_divider')).margin({ left: 16, right: 16 })
  }
  @Builder
  private sectionTitle(title: string) {
    Text(title).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })
  }
  private listPrimaryText(title: string, destructive: boolean = false): TextOptions {
    // 原生文本槽位保留行尾布局空间，只补齐文字的内边距。
    return { text: title, modifier: new TextModifier().fontSize(16)
      .fontColor(destructive ? $r('sys.color.warning') : $r('sys.color.font_primary')).padding({ left: 8 }) };
  }
  @Builder
  private switchRow($$: SwitchEntry) {
    HdsListItemCard({ cardPrefixMargin: 0, cardSuffixMargin: 0, cardBorderRadius: 0,
      textItem: { primaryText: this.listPrimaryText($$.title) },
      suffixItem: new SuffixCustomBuilder(() => { this.switchControl($$); }), enable: !this.busy })
  }
  @Builder
  private switchControl($$: SwitchEntry) {
    Row() {
    Toggle({ type: ToggleType.Switch, isOn: $$.checked }).enabled(!this.busy)
      .systemMaterial(new uiMaterial.ImmersiveMaterial())
      .onChange((checked: boolean) => { if (checked !== $$.checked) { $$.change(checked); } })
    }.padding({ right: 16 })
  }
  @Builder
  private choiceRow($$: ChoiceEntry) {
    HdsListItemCard({ cardPrefixMargin: 0, cardSuffixMargin: 0, cardBorderRadius: 0,
      textItem: { primaryText: this.listPrimaryText($$.title) },
      suffixItem: new SuffixCustomBuilder(() => { this.choiceControl($$); }), enable: !this.busy })
      .onAreaChange((_previous: Area, current: Area) => {
        const width = Number(current.width);
        if (width > 0 && Math.abs(width - this.choiceRowWidth) > 0.5) { this.choiceRowWidth = width; }
      })
  }
  @Builder
  private choiceControl($$: ChoiceEntry) {
    Row() {
    Select($$.options.map((value: string): SelectOption => { return { value: value }; }))
      .selected($$.selected).value($$.value).font({ size: 14, weight: FontWeight.Regular }).fontColor($r('sys.color.font_secondary'))
      .arrowModifier(new SymbolGlyphModifier().fontSize(12).fontColor([$r('sys.color.icon_tertiary')]))
      .showDefaultSelectedIcon(true)
      .optionFont({ size: 16, weight: FontWeight.Regular }).optionFontColor($r('sys.color.font_primary'))
      .selectedOptionFont({ size: 16, weight: FontWeight.Regular }).selectedOptionFontColor($r('sys.color.font_primary'))
      .divider({ strokeWidth: 0.5, color: $r('sys.color.comp_divider'), startMargin: 16, endMargin: 16 })
      .menuAlign(MenuAlignType.END)
      .controlSize(ControlSize.SMALL).enabled(!this.busy)
      .constraintSize({ maxWidth: this.choiceRowWidth > 0 ? Math.max(64, (this.choiceRowWidth - 32) / 2) : 160 })
      // 行内按钮保持透明，独立的菜单继续使用应用级 ENABLE 的系统材质。
      .systemMaterial(uiMaterial.Material.empty).backgroundColor(Color.Transparent)
      .onSelect((index: number) => { $$.change(index); })
    }.padding({ right: 16 })
  }
  @Builder
  private inputRow($$: InputEntry) {
    if ($$.type === InputType.Number || $$.type === InputType.NUMBER_DECIMAL) {
      HdsListItemCard({ cardPrefixMargin: 0, cardSuffixMargin: 0, cardBorderRadius: 0,
        textItem: { primaryText: this.listPrimaryText($$.title),
          secondaryText: $$.subtitle ? { text: $$.subtitle, modifier: new TextModifier().fontSize(12)
            .fontColor($r('sys.color.font_secondary')).padding({ left: 8 }) } : undefined },
        suffixItem: new SuffixCustomBuilder(() => { this.numberControl($$); }), enable: !this.busy })
    } else {
    Column({ space: 4 }) {
      Text($$.title).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
      TextInput({ text: $$.value, placeholder: $$.placeholder || '' }).id($$.id || $$.title)
        .type($$.type === undefined ? InputType.Normal : $$.type).maxLength($$.maxLength === undefined ? Infinity : $$.maxLength)
        .fontSize(16).fontColor($r('sys.color.font_primary')).placeholderFont({ size: 16 })
        .placeholderColor($r('sys.color.font_secondary'))
        .width('100%').height(Math.max(40, 24 * (this.context().config.fontSizeScale ?? 1) + 8))
        .align(Alignment.Center).textAlign(TextAlign.Start)
        .backgroundColor(Color.Transparent).borderRadius(0).padding({ left: 0, right: 0, top: 4, bottom: 4 })
        .accessibilityText($$.title).onChange((value: string) => { $$.change(value); })
    }.padding({ left: 16, right: 16, top: 12, bottom: 4 }).width('100%')
    }
  }
  @Builder
  private numberControl($$: InputEntry) {
    Row() {
      TextInput({ text: $$.value, placeholder: $$.placeholder || '' }).id($$.id || $$.title)
        .type($$.type!).fontSize(16).fontColor($r('sys.color.font_secondary')).placeholderFont({ size: 14 })
        .placeholderColor($r('sys.color.font_secondary')).width(104)
        .height(Math.max(40, 24 * (this.context().config.fontSizeScale ?? 1) + 8))
        .align(Alignment.Center).textAlign(TextAlign.End).backgroundColor(Color.Transparent).borderRadius(0)
        .padding({ left: 4, right: 4, top: 4, bottom: 4 }).enabled(!this.busy)
        .accessibilityText($$.title).onChange((value: string) => { $$.change(value); })
    }.padding({ right: 16 })
  }
  @Builder
  private longValue($$: DetailPair) {
    Column({ space: 6 }) {
      Text($$.label).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
      Text($$.value).fontSize(16).fontColor($r('sys.color.font_primary')).width('100%')
        .wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.LocalDevice)
    }.padding(16).width('100%')
    if (!$$.last) { this.cardDivider() }
  }
  @Builder
  private empty(title: string, subtitle: string) {
    Column({ space: 14 }) {
      SymbolGlyph($r('sys.symbol.arrow_down_circle')).fontSize(48).fontColor([$r('sys.color.icon_tertiary')]).accessibilityLevel('no')
      Text(title).fontSize(22).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
      Text(subtitle).fontSize(15).fontColor($r('sys.color.font_secondary')).textAlign(TextAlign.Center)
    }.width('100%').padding({ top: 48, bottom: 40, left: 24, right: 24 })
  }
  @Builder
  private stats() {
    Row({ space: 12 }) {
      Column({ space: 6 }) {
        Text('↓ 下载速度').fontSize(13).fontColor($r('sys.color.font_secondary'))
        Text(bytes(this.transfer.dl_info_speed) + '/s').fontSize(23).fontWeight(FontWeight.Bold).fontColor($r('sys.color.brand'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Column({ space: 6 }) {
        Text('↑ 上传速度').fontSize(13).fontColor($r('sys.color.font_secondary'))
        Text(bytes(this.transfer.up_info_speed) + '/s').fontSize(23).fontWeight(FontWeight.Bold).fontColor($r('sys.color.font_primary'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.padding(20).width('100%').backgroundColor($r('sys.color.comp_background_primary')).borderRadius(24)
  }
  private rootMenus(): HdsNavigationMenuItemOptions[] {
    if (this.tab !== 0 || !this.connected) { return []; }
    if (this.selecting) {
      return [
        { content: { label: '全选', icon: new SymbolGlyphModifier($r('sys.symbol.checkmark_square_on_square')), action: () => { this.selection = this.visibleTorrents().map((t: Torrent) => t.hash); } } },
        { content: { label: '完成', icon: new SymbolGlyphModifier($r('sys.symbol.checkmark')), action: () => { this.selecting = false; this.selection = []; } } }
      ];
    }
    return [
      { content: { icon: new SymbolGlyphModifier($r('sys.symbol.magnifyingglass')), label: '搜索', action: () => { this.searching = !this.searching; if (!this.searching) { this.query = ''; } } } },
      { content: { icon: new SymbolGlyphModifier($r('sys.symbol.plus')), label: '添加任务', action: () => { this.beginAdd(); } } },
      { content: { icon: new SymbolGlyphModifier($r('sys.symbol.line_3_horizontal')), label: '筛选与排序', action: () => { this.paths.pushPathByName('filters', null); } } },
      { content: { label: '选择任务', action: () => { this.selecting = true; this.selection = []; } } },
      { content: { label: '切换服务器', action: () => { this.paths.pushPathByName('switch', null); } } },
      { content: { label: '刷新', action: () => { this.refresh(true); } } }
    ];
  }
  private bulkTools(): ToolBarOptions {
    const options = new ToolBarOptions();
    const state = this.busy || this.selection.length === 0 ? ItemState.DISABLE : ItemState.ENABLE;
    options.push({ content: '继续', icon: $r('sys.symbol.play_fill'), state: state,
      action: () => { this.operate('start', this.selection); } });
    options.push({ content: '暂停', icon: $r('sys.symbol.pause'), state: state,
      action: () => { this.operate('stop', this.selection); } });
    options.push({ content: '移除', icon: $r('sys.symbol.trash'), state: state,
      iconColor: $r('sys.color.warning'), textColor: $r('sys.color.warning'),
      action: () => { this.confirmBulkDelete(); } });
    options.push({ content: '更多', icon: $r('sys.symbol.line_3_horizontal'), state: state,
      action: () => { this.paths.pushPathByName('bulkActions', null); } });
    return options;
  }
  private updateBulkTools(): void {
    const state = this.busy || this.selection.length === 0 ? ItemState.DISABLE : ItemState.ENABLE;
    this.bulkToolItems.forEach((item) => { item.state = state; });
  }
  @Builder
  private bulkToolbar() {
    ToolBar({ toolBarList: this.bulkToolItems, dividerModifier: new DividerModifier().color(Color.Transparent),
      toolBarModifier: new ToolBarModifier().backgroundColor($r('sys.color.background_secondary')) })
  }
  @Builder
  private refreshIndicator() {
    Row() {
      if (this.refreshing || this.refreshPullOffset > 0) {
        LoadingProgress().width(24).height(24)
      }
    }.width('100%').height(48).justifyContent(FlexAlign.Center)
      .translate({ y: this.searching ? 0 : 56 + this.getUIContext().px2vp(this.statusBarHeightPx) })
  }
  @Builder
  private taskPage() {
    Column({ space: 0 }) {
      this.notice()
      if (!this.connected) {
        if (this.profiles.length === 0) {
          this.empty('尚未配置服务器', '在设置中添加 qBittorrent 服务器。')
          Button('添加服务器').enabled(!this.busy).onClick(() => { this.newServer(); })
        } else {
          if (this.busy) {
            Row({ space: 10 }) {
              LoadingProgress().width(24).height(24)
              Text('正在连接服务器…').fontSize(15).fontColor($r('sys.color.font_secondary'))
            }.width('100%').justifyContent(FlexAlign.Center).padding({ top: 48, bottom: 40 })
          } else {
            this.empty(this.activeName || '连接服务器', '暂时无法连接，请检查网络后重试。')
            Button('重试').onClick(() => {
            const server = this.profiles.find((p: ServerProfile) => p.id === this.activeId) || this.profiles[0];
            if (server) { this.connectSaved(server); }
            })
          }
        }
      } else {
        if (this.searching) {
          Search({ value: this.query, placeholder: '搜索名称，支持 -排除词' }).height(40)
            .onChange((value: string) => { this.query = value; }).margin({ left: 16, right: 16, top: 56 + this.getUIContext().px2vp(this.statusBarHeightPx), bottom: 8 })
        }
        Refresh({ refreshing: $$this.refreshing, builder: this.refreshIndicator }) {
          List({ space: 12, scroller: this.taskScroller }) {
            if (!this.searching) {
              // Keep the initial scroll offset at zero for HDS blur and bottomBuilder linkage.
              ListItem() { Row() {} }.height(92 + this.getUIContext().px2vp(this.statusBarHeightPx))
                .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
            }
            if (!this.visibleCount) {
              ListItem() { this.empty('暂无任务', '添加下载，或调整筛选条件。') }
            }
            LazyForEach(this.taskRows, (row: TorrentRowData) => {
              ListItem() {
                TorrentCard({ row: row, selecting: this.selecting, checked: this.selection.includes(row.torrent.hash),
                  onToggle: (hash: string) => { this.toggleSelection(hash); },
                  onSelect: (hash: string) => { this.selecting = true; this.toggleSelection(hash); },
                  onOpen: (torrent: Torrent) => { this.openDetails(torrent); } })
              }
            }, (row: TorrentRowData) => row.torrent.hash)
          }.width('100%').height('100%').padding({ left: 16, right: 16 }).edgeEffect(EdgeEffect.Spring).clipContent(this.taskListWidth > 0 ? new RectShape({ width: this.taskListWidth, height: this.taskListHeight + this.getUIContext().px2vp(this.statusBarHeightPx + this.navigationBarHeightPx) }).offset({ x: 0, y: -this.getUIContext().px2vp(this.statusBarHeightPx) }) : ContentClipMode.SAFE_AREA)
            .onAreaChange((_previous: Area, current: Area) => { this.taskListWidth = Number(current.width); this.taskListHeight = Number(current.height); }).cachedCount(3).contentStartOffset(this.searching ? 8 : 0).contentEndOffset(this.selecting ? 20 : 80)
            .scrollBarMargin({ start: LengthMetrics.vp(this.searching ? 8 : 64 + this.getUIContext().px2vp(this.statusBarHeightPx)), end: LengthMetrics.vp(this.selecting ? 20 : 80) })
            .onDidScroll(() => {
              const offset = Math.max(0, this.taskScroller.currentOffset().yOffset);
              this.taskScrolled = offset > 0.5;
              this.taskBlurProgress = Math.min(1, offset / 8);
              this.summaryMotion.progress = Math.min(1, offset / 16);
            })
            .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
        }.layoutWeight(1).clip(false).refreshOffset(64).maxPullDownDistance(96)
          .onOffsetChange((offset: number) => { this.refreshPullOffset = offset; })
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM]).onRefreshing(() => { this.refresh(true); })

      }
    }.width('100%').height('100%').padding({ left: this.connected ? 0 : 16, right: this.connected ? 0 : 16, top: this.connected && !this.error ? 0 : 56 + this.getUIContext().px2vp(this.statusBarHeightPx) })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
  @LocalBuilder
  private taskSummary() {
    TaskSummaryContent({ motion: this.summaryMotion,
      countText: `${FILTER_LABELS[this.filter]} · ${this.visibleCount} 项`,
      speedText: this.selecting ? '' : `↓ ${bytes(this.transfer.dl_info_speed)}/s  ↑ ${bytes(this.transfer.up_info_speed)}/s` })
  }
  @Builder
  private serversPage() {
    Scroll(this.pageScroller('servers')) {
      Column({ space: 12 }) {
        this.notice()
        if (this.profiles.length > 0) {
          Column() {
            ForEach(this.profiles, (profile: ServerProfile, index: number) => {
              HdsListItemCard({ cardPrefixMargin: 0, cardSuffixMargin: 0, cardBorderRadius: 0,
                textItem: { primaryText: this.listPrimaryText(profile.name + (profile.id === this.activeId ? ' · 当前' : '')),
                  secondaryText: this.settings.hideUrls ? undefined : { text: profile.url,
                    modifier: new TextModifier().fontSize(14).fontColor($r('sys.color.font_secondary')).padding({ left: 8 }) } },
                suffixItem: new SuffixArrow(), onClick: () => { this.editServer(profile); }, enable: !this.busy })
              if (index < this.profiles.length - 1) { this.cardDivider() }
            }, (profile: ServerProfile) => JSON.stringify(profile))
          }.groupedCard()
        } else { this.empty('尚未添加服务器', '轻点右上角添加你的 qBittorrent 服务器。') }
      }.padding({ left: 16, right: 16, top: 12, bottom: 24 }).width('100%')
    }.secondaryScroll()
  }
  @Builder
  private settingRow($$: SettingsEntry) {
    HdsListItemCard({ cardPrefixMargin: 0, cardSuffixMargin: 0, cardBorderRadius: 0,
      textItem: { primaryText: this.listPrimaryText($$.title) },
      suffixItem: $$.subtitle ? new SuffixTextAndArrow({ text: $$.subtitle,
        modifier: new TextModifier().fontSize(14).fontColor($r('sys.color.font_secondary')) }, { color: $r('sys.color.icon_tertiary') })
        : new SuffixArrow({ color: $r('sys.color.icon_tertiary') }),
      onClick: () => { this.paths.pushPathByName($$.route, null); }, enable: !this.busy })
  }
  @Builder
  private actionRow($$: ActionEntry) {
    HdsListItemCard({ cardPrefixMargin: 0, cardSuffixMargin: 0, cardBorderRadius: 0,
      textItem: { primaryText: this.listPrimaryText($$.title, $$.destructive === true) },
      suffixItem: $$.opensPage ? new SuffixArrow() : undefined,
      onClick: $$.action, enable: !this.busy })
  }
  @Builder
  private settingsPage() {
    Scroll(this.settingsScroller) {
      Column({ space: 12 }) {
        this.notice()
        Column() {
          this.settingRow({ title: '服务器', subtitle: `${this.profiles.length} 个配置`, route: 'servers' })
        }.groupedCard()
        Column() {
          this.settingRow({ title: '常规', subtitle: '', route: 'general' })
          this.cardDivider()
          this.settingRow({ title: '外观', subtitle: ['跟随系统', '浅色模式', '深色模式'][this.settings.theme], route: 'appearance' })
          this.cardDivider()
          this.settingRow({ title: '网络', subtitle: '', route: 'network' })
          this.cardDivider()
          this.settingRow({ title: '通知', subtitle: this.notificationStatus, route: 'notifications' })
        }.groupedCard()
        Column() {
          if (this.connected) {
            this.settingRow({ title: '连接与传输', subtitle: '', route: 'connection' })
            this.cardDivider()
          }
          this.settingRow({ title: '关于', subtitle: '0.1.0', route: 'about' })
        }.groupedCard()
      }.padding({ left: 16, right: 16, top: 72 + this.getUIContext().px2vp(this.statusBarHeightPx), bottom: 96 }).width('100%')
    }.secondaryScroll()
  }
  @Builder
  private preferencesPage(name: string) {
    Column({ space: 12 }) {
      this.notice()
      if (name === 'general') {
        Column() {
          this.switchRow({ title: '记住上次使用的服务器', checked: this.settings.rememberServer,
            change: (v: boolean) => { this.settings.rememberServer = v; this.saveSettings(); } })
          this.cardDivider()
          this.switchRow({ title: '隐藏服务器地址', checked: this.settings.hideUrls,
            change: (v: boolean) => { this.settings.hideUrls = v; this.saveSettings(); } })
        }.groupedCard()
      } else if (name === 'notifications') {
        Column() {
          this.switchRow({ title: '下载完成通知', checked: this.notificationEnabled,
            change: (v: boolean) => { this.configureNotifications(v ? 'enable' : 'disable'); } })
          this.cardDivider()
          this.pair({ label: '通知状态', value: this.notificationStatus, last: true })
        }.groupedCard()
        Column() {
          this.pair({ label: '后台检查', value: '系统调度，可能延迟数小时' })
          this.actionRow({ title: '系统通知设置', opensPage: true, action: () => { this.configureNotifications('settings'); } })
        }.groupedCard()
      } else if (name === 'appearance') {
        Column() {
          this.choiceRow({ title: '颜色模式', options: ['跟随系统', '浅色模式', '深色模式'], selected: this.settings.theme,
            value: ['跟随系统', '浅色模式', '深色模式'][this.settings.theme],
            change: (i: number) => { this.settings.theme = i; this.saveSettings(); } })
        }.groupedCard()
      } else if (name === 'network') {
        Column() {
          this.choiceRow({ title: '自动刷新间隔', options: ['手动刷新', '3 秒', '5 秒', '10 秒', '30 秒'],
            selected: [0, 3, 5, 10, 30].indexOf(this.settings.refreshSeconds), value: this.settings.refreshSeconds ? `${this.settings.refreshSeconds} 秒` : '手动刷新',
            change: (i: number) => { this.settings.refreshSeconds = [0, 3, 5, 10, 30][i]; this.saveSettings(); } })
          this.cardDivider()
          this.choiceRow({ title: '连接超时', options: ['5 秒', '10 秒', '20 秒', '30 秒'],
            selected: [5, 10, 20, 30].indexOf(this.settings.timeoutSeconds), value: `${this.settings.timeoutSeconds} 秒`,
            change: (i: number) => { this.settings.timeoutSeconds = [5, 10, 20, 30][i]; this.saveSettings(); } })
        }.groupedCard()
      } else if (name === 'connection') {
        Column() {
          this.pair({ label: '服务器', value: this.activeName })
          this.pair({ label: '版本', value: this.version })
          this.pair({ label: '连接状态', value: this.transfer.connection_status === 'connected' ? '已连接' : this.transfer.connection_status === 'firewalled' ? '连接受限' : this.transfer.connection_status === 'disconnected' ? '未连接' : '—', last: true })
        }.groupedCard()
        Column() {
          this.pair({ label: '累计下载', value: bytes(this.transfer.dl_info_data) })
          this.pair({ label: '累计上传', value: bytes(this.transfer.up_info_data) })
          this.actionRow({ title: '速度限制', opensPage: true, action: () => {
            this.downloadLimit = String(Math.round(this.transfer.dl_rate_limit / 1024));
            this.uploadLimit = String(Math.round(this.transfer.up_rate_limit / 1024));
            this.paths.pushPathByName('limits', null);
          } })
        }.groupedCard()
      } else if (name === 'switch') {
        Column() {
          ForEach(this.profiles, (profile: ServerProfile, index: number) => {
            this.actionRow({ title: profile.name + (profile.id === this.activeId ? ' · 当前' : ''), action: () => { this.connectSaved(profile); } })
            if (index < this.profiles.length - 1) { this.cardDivider() }
          }, (profile: ServerProfile) => profile.id)
        }.groupedCard()
      } else if (name === 'filters') {
        Column() {
          this.choiceRow({ title: '任务状态', options: FILTER_LABELS, selected: this.filter, value: FILTER_LABELS[this.filter], change: (i: number) => { this.filter = i; } })
          this.cardDivider()
          this.choiceRow({ title: '排序', options: SORT_LABELS, selected: this.sort, value: SORT_LABELS[this.sort], change: (i: number) => { this.sort = i; this.saveSort(); } })
          this.cardDivider()
          this.switchRow({ title: '反向排序', checked: this.reverseSort, change: (v: boolean) => { this.reverseSort = v; this.saveSort(); } })
        }.groupedCard()
        Column() {
          this.choiceRow({ title: '分类', options: ['全部分类', '未分类'].concat(this.categories.map((c: Category): string => c.name)),
            selected: this.categoryFilter === '\u0000' ? 1 : this.categoryFilter ? this.categories.findIndex((c: Category): boolean => c.name === this.categoryFilter) + 2 : 0,
            value: this.categoryFilter === '\u0000' ? '未分类' : this.categoryFilter || '全部分类',
            change: (i: number) => { this.categoryFilter = i === 0 ? '' : i === 1 ? '\u0000' : this.categories[i - 2].name; } })
          this.cardDivider()
          this.choiceRow({ title: '标签', options: ['全部标签', '无标签'].concat(this.tags),
            selected: this.tagFilter === '\u0000' ? 1 : this.tagFilter ? this.tags.indexOf(this.tagFilter) + 2 : 0,
            value: this.tagFilter === '\u0000' ? '无标签' : this.tagFilter || '全部标签',
            change: (i: number) => { this.tagFilter = i === 0 ? '' : i === 1 ? '\u0000' : this.tags[i - 2]; } })
          this.cardDivider()
          this.choiceRow({ title: 'Tracker', options: ['全部 Tracker', '无 Tracker'].concat(Object.keys(this.trackerMap)),
            selected: this.trackerFilter === '\u0000' ? 1 : this.trackerFilter ? Object.keys(this.trackerMap).indexOf(this.trackerFilter) + 2 : 0,
            value: this.trackerFilter === '\u0000' ? '无 Tracker' : this.trackerFilter || '全部 Tracker',
            change: (i: number) => { this.trackerFilter = i === 0 ? '' : i === 1 ? '\u0000' : Object.keys(this.trackerMap)[i - 2]; } })
        }.groupedCard()
        Column() {
          this.actionRow({ title: '重置筛选', action: () => { this.filter = 0; this.query = ''; this.categoryFilter = ''; this.tagFilter = ''; this.trackerFilter = ''; } })
        }.groupedCard()
        Button('完成').width('100%').onClick(() => { this.paths.pop(); })
      } else {
        Column({ space: 8 }) {
          Image($r('app.media.qbit_icon')).width(64).height(64).borderRadius(16)
          Text('下载遥控').fontSize(24).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
          Text('0.1.0').fontSize(14).fontColor($r('sys.color.font_secondary'))
        }.width('100%').padding({ top: 24, bottom: 24 })
        Column() {
          this.pair({ label: '开源许可', value: 'GPL-3.0' })
          this.longValue({ label: '原项目', value: 'Bartuzen/qBitController', last: true })
        }.groupedCard()
      }
    }.padding({ left: 16, right: 16, top: 12, bottom: 24 }).width('100%')
  }
  private pageTitle(name: string): string {
    if (name === 'notifications') { return '通知'; }
    if (name === 'bulkActions') { return `管理 ${this.selection.length} 个任务`; }
    if (name === 'taskRules') { return '限速与做种规则'; }
    if (name === 'editTorrent' && this.editAction === 'category') { return '设置分类'; }
    if (name === 'editTorrent') { return this.editAction === 'rename' ? '重命名' : this.editAction === 'location' ? '设置保存路径' : this.editAction === 'removeTags' ? '移除标签' : '添加标签'; }
    if (name === 'torrentActions') { return '任务操作'; }
    if (name === 'server') { return '服务器配置'; }
    if (name === 'servers') { return '服务器'; }
    if (name === 'add') { return '添加任务'; }
    if (name === 'detail') { return '任务详情'; }
    if (name === 'limits') { return '速度限制'; }
    if (name === 'general') { return '常规'; }
    if (name === 'appearance') { return '外观'; }
    if (name === 'network') { return '网络'; }
    if (name === 'connection') { return '连接与传输'; }
    if (name === 'switch') { return '切换服务器'; }
    if (name === 'filters') { return '筛选与排序'; }
    return '关于';
  }
  @Builder
  private serverForm() {
    Column({ space: 12 }) {
      this.notice()
      Column() {
        this.inputRow({ title: '名称', value: this.serverName, placeholder: '例如：家里的 NAS', id: 'serverName', maxLength: 80, change: (v: string) => { this.serverName = v; } })
        this.cardDivider()
        this.inputRow({ title: 'qBittorrent WebUI 地址', value: this.serverUrl, placeholder: 'http://192.168.1.10:8080', id: 'serverUrl', change: (v: string) => { this.serverUrl = v; } })
      }.groupedCard()
      Column() {
        this.inputRow({ title: '用户名', value: this.username, placeholder: 'admin', id: 'serverUsername', change: (v: string) => { this.username = v; } })
        this.cardDivider()
        this.inputRow({ title: '密码', value: this.password, placeholder: 'WebUI 密码', type: InputType.Password, id: 'serverPassword', change: (v: string) => { this.password = v; } })
        this.cardDivider()
        this.switchRow({ title: '安全保存密码', checked: this.remember, change: (v: boolean) => { this.remember = v; } })
      }.groupedCard()
      Column() {
        this.actionRow({ title: '测试配置', action: () => { this.testServer(); } })
      }.groupedCard()
      Button(this.busy ? '正在保存…' : '保存').id('saveServer').width('100%').enabled(!this.busy).onClick(() => { this.saveServer(); })
      if (this.editId) {
        Column() {
          this.actionRow({ title: '删除此服务器配置', destructive: true, action: () => {
            const profile = this.profiles.find((p: ServerProfile) => p.id === this.editId);
            if (profile) { this.forgetServer(profile); }
          } })
        }.groupedCard()
      }
    }.padding({ left: 16, right: 16, top: 12, bottom: 24 }).width('100%')
  }
  @Builder
  private addForm() {
    Column({ space: 12 }) {
      this.notice()
      Column() {
        if (this.profiles.length > 0) {
          this.choiceRow({ title: '目标服务器', options: this.profiles.map((p: ServerProfile): string => p.name),
            value: this.activeName || '选择服务器', selected: this.profiles.findIndex((p: ServerProfile): boolean => p.id === this.activeId),
            change: (index: number) => { this.connectSaved(this.profiles[index], false); } })
          if (!this.connected) {
            this.cardDivider()
            this.actionRow({ title: '连接服务器', action: () => {
              const profile = this.profiles.find((p: ServerProfile): boolean => p.id === this.activeId) || this.profiles[0];
              this.connectSaved(profile, false);
            } })
          }
        } else { this.actionRow({ title: '添加服务器', opensPage: true, action: () => { this.newServer(); } }) }
      }.groupedCard()
      Column() {
        Column({ space: 8 }) {
          Text('磁力链接 / 种子下载地址').fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
          TextArea({ text: this.links, placeholder: 'magnet:?xt=urn:btih:…\n支持多个链接，每行一个' }).id('torrentLinks')
            .height(128).fontSize(16).fontColor($r('sys.color.font_primary')).placeholderFont({ size: 16 })
            .placeholderColor($r('sys.color.font_secondary')).backgroundColor(Color.Transparent).borderRadius(0)
            .padding(0).enabled(!this.uploadName).onChange((v: string) => { this.links = v; })
        }.padding(16).width('100%')
        this.cardDivider()
        this.actionRow({ title: this.uploadName || '选择 .torrent 文件', opensPage: true, action: () => { this.pickTorrent(); } })
        if (this.uploadName) {
          this.cardDivider()
          this.actionRow({ title: '取消文件，改用链接', action: () => { this.upload = undefined; this.uploadName = ''; } })
        }
      }.groupedCard()
      Column() {
        this.inputRow({ title: '服务器保存路径', value: this.savePath, placeholder: '留空使用服务器默认路径', change: (v: string) => { this.savePath = v; } })
        this.cardDivider()
        this.choiceRow({ title: '分类', options: ['未分类'].concat(this.categories.map((c: Category): string => c.name)),
          value: this.addCategory || '未分类', selected: this.addCategory ? this.categories.findIndex((c: Category): boolean => c.name === this.addCategory) + 1 : 0,
          change: (i: number) => { this.addCategory = i === 0 ? '' : this.categories[i - 1].name; } })
        this.cardDivider()
        this.inputRow({ title: '标签', value: this.addOptions.tags, placeholder: '多个标签用逗号分隔', change: (v: string) => { this.addOptions.tags = v; } })
        this.cardDivider()
        this.inputRow({ title: '重命名', value: this.addOptions.rename, placeholder: '留空保留原种子名称', change: (v: string) => { this.addOptions.rename = v; } })
      }.groupedCard()
      Column() {
        this.switchRow({ title: '添加后暂停', checked: this.startStopped, change: (v: boolean) => { this.startStopped = v; } })
        this.cardDivider()
        this.switchRow({ title: '顺序下载', checked: this.addOptions.sequential, change: (v: boolean) => { this.addOptions.sequential = v; } })
        this.cardDivider()
        this.switchRow({ title: '优先下载首尾分块', checked: this.addOptions.firstLast, change: (v: boolean) => { this.addOptions.firstLast = v; } })
        this.cardDivider()
        this.choiceRow({ title: '种子管理模式', options: ['使用服务器默认', '手动管理', '自动管理'],
          selected: this.addOptions.autoTmm, value: ['使用服务器默认', '手动管理', '自动管理'][this.addOptions.autoTmm],
          change: (i: number) => { this.addOptions.autoTmm = i; } })
      }.groupedCard()
      Column() {
        this.inputRow({ title: '下载限速', subtitle: 'KiB/s，0 为不限速', value: this.addOptions.downloadLimit, placeholder: '0 为不限速', type: InputType.Number, change: (v: string) => { this.addOptions.downloadLimit = v; } })
        this.cardDivider()
        this.inputRow({ title: '上传限速', subtitle: 'KiB/s，0 为不限速', value: this.addOptions.uploadLimit, placeholder: '0 为不限速', type: InputType.Number, change: (v: string) => { this.addOptions.uploadLimit = v; } })
      }.groupedCard()
      Button('添加下载任务').id('addTorrent').width('100%').enabled(!this.busy && this.connected).onClick(() => { this.addTorrent(); })
    }.padding({ left: 16, right: 16, top: 12, bottom: 24 }).width('100%').enabled(!this.busy)
  }
  @LocalBuilder
  private detailTabs() {
    DetailTabStrip({ selection: this.detailTabSelection, change: (index: number) => {
      this.detailTabsController.changeIndex(index);
    }, measure: () => { this.updateDetailHeaderBounds(); } })
  }
  private detailContentInset(): number {
    // 视口延伸到屏幕顶部；首项只避让实际可见的原生标题和页签。
    return (this.detailHeaderBottom || this.getUIContext().px2vp(this.statusBarHeightPx) + 100) + 12;
  }
  @Builder
  private detailListInset() {
    ListItem() { Row() {} }.height(this.detailContentInset()).hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
  }
  private updateDetailHeaderBounds(): void {
    const node = this.getUIContext().getFrameNodeById('detailTabStrip');
    if (!node) { return; }
    const bottom = node.getPositionToWindowWithTransform().y + this.getUIContext().px2vp(node.getMeasuredSize().height);
    if (Math.abs(bottom - this.detailHeaderBottom) > 0.5) {
      this.detailHeaderBottom = bottom;
    }
  }
  private rememberDetailScroll(index: number): void {
    this.detailScrollOffsets[index] = Math.max(0, this.pageScroller('detail-' + index).currentOffset().yOffset);
  }
  private activateDetailTab(index: number): void {
    // 切换开始时改绑目标页，避免沿用上一页的标题安全区和模糊进度。
    this.updateDetailHeaderBounds();
    this.detailTabSelection.index = index;
  }
  private restoreDetailScroll(index: number): void {
    // 列表首次进入时可能尚未布局，待切换落定后的布局帧再恢复。
    this.getUIContext().postFrameCallback(new DetailLayoutReady(() => {
      if (index !== this.detailTabSelection.index) { return; }
      this.updateDetailHeaderBounds();
      this.pageScroller('detail-' + index).scrollTo({ xOffset: 0,
        yOffset: this.detailScrollOffsets[index], animation: false });
    }));
  }
  @Builder
  private detailSummary() {
      Column({ space: 10 }) {
        Text(this.selected!.name).fontSize(16).fontWeight(FontWeight.Medium).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('sys.color.font_primary')).width('100%').copyOption(CopyOptions.LocalDevice)
        Progress({ value: percent(this.selected!.progress), total: 100, type: ProgressType.Linear }).width('100%').color($r('sys.color.brand'))
        Row() {
          Text(stateLabel(this.selected!.state)).fontSize(12).fontColor($r('sys.color.font_secondary')).layoutWeight(1)
          Text(`${percent(this.selected!.progress)}% · ${bytes(this.selected!.size)}`).fontSize(12).fontColor($r('sys.color.font_secondary'))
        }.width('100%')
      }.padding(16).groupedCard()
  }
  @Builder
  private detailPage() {
    Column() {
      Tabs({ index: this.detailContentIndex, controller: this.detailTabsController }) {
        TabContent() {
          Scroll(this.pageScroller('detail-0')) {
            Column({ space: 0 }) {
              this.notice()
              this.detailSummary()
              if (this.detailError) { Text('详情刷新失败：' + this.detailError).fontSize(14).fontColor($r('sys.color.warning')).width('100%').padding(12) }
              this.sectionTitle('基本信息')
              Column() {
                this.pair({ label: '任务大小', value: bytes(this.selected!.size) })
                this.pair({ label: '添加时间', value: this.dateText(this.properties.addition_date || this.selected!.added_on) })
                this.pair({ label: '完成时间', value: this.dateText(this.properties.completion_date || this.selected!.completion_on) })
                this.pair({ label: '剩余时间', value: duration(this.selected!.eta), last: true })
              }.groupedCard()
              this.sectionTitle('传输信息')
              Column() {
                this.pair({ label: '下载速度', value: bytes(this.selected!.dlspeed) + '/s' })
                this.pair({ label: '上传速度', value: bytes(this.selected!.upspeed) + '/s' })
                this.pair({ label: '已下载', value: this.amountText(this.selected!.downloaded) })
                this.pair({ label: '本次下载', value: this.amountText(this.selected!.downloaded_session) })
                this.pair({ label: '已上传', value: this.amountText(this.selected!.uploaded) })
                this.pair({ label: '本次上传', value: this.amountText(this.selected!.uploaded_session) })
                this.pair({ label: '分享率', value: this.selected!.ratio.toFixed(2) })
                this.pair({ label: '活动时间', value: this.elapsedText(this.selected!.time_active) })
                this.pair({ label: '做种时间', value: this.elapsedText(this.selected!.seeding_time) })
                this.pair({ label: '最近活动', value: this.dateText(this.selected!.last_activity), last: true })
              }.groupedCard()
              this.sectionTitle('连接信息')
              Column() {
                this.pair({ label: '种子 / 用户', value: `${this.selected!.num_seeds} / ${this.selected!.num_leechs}` })
                this.pair({ label: '连接数 / 上限', value: String(this.properties.nb_connections ?? '—') + ' / ' + (this.properties.nb_connections_limit === -1 ? '不限' : String(this.properties.nb_connections_limit ?? '—')) })
                this.pair({ label: '下次汇报', value: this.elapsedText(this.properties.reannounce) })
                this.pair({ label: '上次见到完整任务', value: this.dateText(this.selected!.seen_complete) })
                this.pair({ label: '浪费数据', value: this.amountText(this.properties.total_wasted), last: true })
              }.groupedCard()
              this.sectionTitle('任务属性')
              Column() {
                this.pair({ label: '分类', value: this.selected!.category || '未分类' })
                this.pair({ label: '标签', value: this.selected!.tags || '无' })
                this.longValue({ label: '保存路径', value: this.selected!.save_path })
                this.longValue({ label: 'Hash', value: this.selected!.hash, last: true })
              }.groupedCard()
            }.padding({ left: 16, right: 16, top: this.detailContentInset(), bottom: 24 }).width('100%')
          }.align(Alignment.TopStart).height('100%').width('100%').clipContent(ContentClipMode.SAFE_AREA)
            .scrollBarMargin({ start: LengthMetrics.vp(this.detailContentInset()), end: LengthMetrics.vp(24) })
            .onDidScroll(() => { this.updateDetailHeaderBounds(); }).onScrollStop(() => { this.updateDetailHeaderBounds(); })
            .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
        }.onWillHide(() => { this.rememberDetailScroll(0); })
          .clip(false).expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
        TabContent() { this.filesPage()
        }.onWillHide(() => { this.rememberDetailScroll(1); })
          .clip(false).expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
        TabContent() {
          List({ scroller: this.pageScroller('detail-2') }) {
            this.detailListInset()
            if (this.error) { ListItem() { this.notice() }.padding({ left: 16, right: 16 }) }
            ListItem() {
            Row({ space: 8 }) {
              Text(`${this.trackers.length} 项`).fontSize(12).fontColor($r('sys.color.font_secondary')).layoutWeight(1)
              Button('重新汇报').fontSize(14).fontWeight(FontWeight.Regular).padding({ left: 8, right: 8 })
                .backgroundColor(Color.Transparent).fontColor($r('sys.color.brand')).enabled(!this.busy)
                .onClick(() => { this.operate('reannounce', [this.selected!.hash]); })
            }.width('100%').height(40).padding({ left: 32, right: 32 })
            }
              if (this.trackers.length === 0) {
                ListItem() { this.empty(this.detailLoading ? '正在加载…' : '暂无 Tracker', '') }
              } else {
                ListItemGroup() {
                  ForEach(this.trackers, (tracker: Tracker) => {
                    ListItem() {
                      Column({ space: 4 }) {
                        Text(tracker.url.startsWith('**') ? tracker.url.replace(/\*/g, '').replace(/\[|\]/g, '').trim() : tracker.url)
                          .fontSize(14).fontColor($r('sys.color.font_primary')).maxLines(2)
                          .wordBreak(WordBreak.BREAK_ALL).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').copyOption(CopyOptions.LocalDevice)
                        Text(`${['禁用', '未联系', '正常', '更新中', '未连接'][tracker.status] || '未知'} · 用户 ${tracker.num_peers < 0 ? '—' : tracker.num_peers}`)
                          .fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
                        if (tracker.msg) {
                          Text(tracker.msg).fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
                            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).copyOption(CopyOptions.LocalDevice)
                        }
                      }.width('100%').padding(16).constraintSize({ minHeight: 64 })
                    }
                  }, (tracker: Tracker): string => tracker.url)
                }.groupedCard().width('calc(100% - 32vp)').margin({ left: 16, right: 16 })
                  .divider({ strokeWidth: 0.5, color: $r('sys.color.comp_divider'), startMargin: 16, endMargin: 16 })
              }
          }.height('100%').width('100%').contentEndOffset(24).clipContent(ContentClipMode.SAFE_AREA)
            .scrollBarMargin({ start: LengthMetrics.vp(this.detailContentInset()), end: LengthMetrics.vp(24) })
            .onDidScroll(() => { this.updateDetailHeaderBounds(); }).onScrollStop(() => { this.updateDetailHeaderBounds(); })
            .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
        }.onWillHide(() => { this.rememberDetailScroll(2); })
          .clip(false).expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
        TabContent() {
          List({ space: 12, scroller: this.pageScroller('detail-3') }) {
            this.detailListInset()
            if (this.error) { ListItem() { this.notice() }.padding({ left: 16, right: 16 }) }
            if (this.peerError) {
              ListItem() { Text('用户信息刷新失败：' + this.peerError).fontSize(14).fontColor($r('sys.color.warning')).padding(16) }
            } else if (this.peers.length === 0) {
              ListItem() { this.empty(this.detailLoading ? '正在加载用户…' : '暂无连接用户', '') }
            }
            ForEach(this.peers, (peer: TorrentPeer) => {
              ListItem() {
                Column() {
                  Column({ space: 4 }) {
                    Text((peer.ip.includes(':') ? '[' + peer.ip + ']' : peer.ip) + ':' + peer.port)
                      .fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).width('100%').copyOption(CopyOptions.LocalDevice)
                    Text((peer.client || '未知客户端') + ' · ' + (peer.connection || '—')).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
                  }.padding(16).width('100%')
                  this.cardDivider()
                  this.pair({ label: '进度', value: percent(peer.progress) + '%' })
                  this.pair({ label: '下载 / 上传', value: bytes(peer.dl_speed) + '/s / ' + bytes(peer.up_speed) + '/s' })
                  this.pair({ label: '已下载 / 已上传', value: bytes(peer.downloaded) + ' / ' + bytes(peer.uploaded) })
                  this.pair({ label: '连接标志', value: peer.flags || '—', last: true })
                }.groupedCard()
              }.padding({ left: 16, right: 16 })
            }, (peer: TorrentPeer) => JSON.stringify(peer))
          }.width('100%').height('100%').contentEndOffset(24).clipContent(ContentClipMode.SAFE_AREA)
            .scrollBarMargin({ start: LengthMetrics.vp(this.detailContentInset()), end: LengthMetrics.vp(24) })
            .onDidScroll(() => { this.updateDetailHeaderBounds(); }).onScrollStop(() => { this.updateDetailHeaderBounds(); })
            .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
        }.onWillHide(() => { this.rememberDetailScroll(3); })
          .clip(false).expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
      }.onAnimationStart((_index: number, targetIndex: number) => { this.activateDetailTab(targetIndex); })
        .onChange((index: number) => { this.detailContentIndex = index; })
        .onAnimationEnd((index: number) => {
          // 手势取消时以实际落定页为准，恢复选中态及导航绑定。
          if (index !== this.detailTabSelection.index) { this.activateDetailTab(index); }
          this.restoreDetailScroll(index);
        })
        .layoutWeight(1).barHeight(0).clip(false)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    }.width('100%').height('100%').expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
  @Builder
  private limitForm() {
    Column({ space: 12 }) {
      this.notice()
      Column() {
        this.inputRow({ title: '下载限速', subtitle: 'KiB/s，0 为不限速', value: this.downloadLimit, type: InputType.Number, change: (v: string) => { this.downloadLimit = v; } })
        this.cardDivider()
        this.actionRow({ title: '保存下载限速', action: () => { this.setLimit('Download', this.downloadLimit); } })
      }.groupedCard()
      Column() {
        this.inputRow({ title: '上传限速', subtitle: 'KiB/s，0 为不限速', value: this.uploadLimit, type: InputType.Number, change: (v: string) => { this.uploadLimit = v; } })
        this.cardDivider()
        this.actionRow({ title: '保存上传限速', action: () => { this.setLimit('Upload', this.uploadLimit); } })
      }.groupedCard()
    }.padding({ left: 16, right: 16, top: 12, bottom: 24 }).width('100%').enabled(!this.busy)
  }
  @Builder
  private destination(name: string) {
    HdsNavDestination() {
      Column() {
        if (name === 'server') { Scroll(this.pageScroller(name)) { this.serverForm() }.secondaryScroll() }
        else if (name === 'servers') { this.serversPage() }
        else if (name === 'taskRules') { Scroll(this.pageScroller(name)) { this.taskRulesForm() }.secondaryScroll() }
        else if (name === 'bulkActions') {
          Scroll(this.pageScroller(name)) {
            Column({ space: 12 }) {
              this.notice()
              Column() {
                this.actionRow({ title: '设置分类', opensPage: true, action: () => { this.openEdit('category', true); } })
                this.cardDivider()
                this.actionRow({ title: '设置保存路径', opensPage: true, action: () => { this.openEdit('location', true); } })
                this.cardDivider()
                this.actionRow({ title: '添加标签', opensPage: true, action: () => { this.openEdit('addTags', true); } })
                this.cardDivider()
                this.actionRow({ title: '移除标签', opensPage: true, action: () => { this.openEdit('removeTags', true); } })
              }.groupedCard()
              Column() {
                this.actionRow({ title: '队列置顶', action: () => { this.operate('topPrio', this.selection); } })
                this.cardDivider()
                this.actionRow({ title: '队列优先级提高', action: () => { this.operate('increasePrio', this.selection); } })
                this.cardDivider()
                this.actionRow({ title: '队列优先级降低', action: () => { this.operate('decreasePrio', this.selection); } })
                this.cardDivider()
                this.actionRow({ title: '队列置底', action: () => { this.operate('bottomPrio', this.selection); } })
              }.groupedCard()
            }.padding({ left: 16, right: 16, top: 12, bottom: 24 }).width('100%').enabled(!this.busy && this.selection.length > 0)
          }.secondaryScroll()
        } else if (name === 'editTorrent') {
          Scroll(this.pageScroller(name)) {
            Column({ space: 12 }) {
              this.notice()
              Column() {
                this.inputRow({ title: this.pageTitle(name), value: this.editValue, change: (v: string) => { this.editValue = v; } })
              }.groupedCard()
              Button('保存').width('100%').enabled(!this.busy).onClick(() => { this.applyTorrentEdit(); })
            }.padding({ left: 16, right: 16, top: 12, bottom: 24 }).width('100%')
          }.secondaryScroll()
        } else if (name === 'torrentActions') {
          Scroll(this.pageScroller(name)) {
            Column({ space: 12 }) {
              this.notice()
              if (this.selected) {
                Column() {
                  this.actionRow({ title: '限速与做种规则', opensPage: true, action: () => { this.openTaskRules(); } })
                  this.cardDivider()
                  this.actionRow({ title: '分享磁力链接', action: () => { this.shareMagnet(); } })
                  this.cardDivider()
                  this.actionRow({ title: '导出种子文件', action: () => { this.exportSelected(); } })
                }.groupedCard()
                Column() {
                  this.actionRow({ title: '设置分类', opensPage: true, action: () => { this.openEdit('category'); } })
                  this.cardDivider()
                  this.actionRow({ title: '重命名', opensPage: true, action: () => { this.openEdit('rename'); } })
                  this.cardDivider()
                  this.actionRow({ title: '设置保存路径', opensPage: true, action: () => { this.openEdit('location'); } })
                  this.cardDivider()
                  this.actionRow({ title: '添加标签', opensPage: true, action: () => { this.openEdit('addTags'); } })
                  this.cardDivider()
                  this.actionRow({ title: '移除标签', opensPage: true, action: () => { this.openEdit('removeTags'); } })
                }.groupedCard()
                Column() {
                  this.actionRow({ title: '强制重新校验', action: () => { if (this.selected) { this.operate('recheck', [this.selected.hash]); } } })
                  this.cardDivider()
                  this.actionRow({ title: this.selected.force_start ? '取消强制启动' : '强制启动', action: () => { if (this.selected) { this.toggleForce(this.selected); } } })
                  this.cardDivider()
                  this.actionRow({ title: this.selected.seq_dl ? '关闭顺序下载' : '启用顺序下载', action: () => { if (this.selected) { this.operate('toggleSequentialDownload', [this.selected.hash]); } } })
                  this.cardDivider()
                  this.actionRow({ title: this.selected.f_l_piece_prio ? '关闭首尾分块优先' : '启用首尾分块优先', action: () => { if (this.selected) { this.operate('toggleFirstLastPiecePrio', [this.selected.hash]); } } })
                }.groupedCard()
                Column() {
                  this.actionRow({ title: '队列优先级提高', action: () => { if (this.selected) { this.operate('increasePrio', [this.selected.hash]); } } })
                  this.cardDivider()
                  this.actionRow({ title: '队列优先级降低', action: () => { if (this.selected) { this.operate('decreasePrio', [this.selected.hash]); } } })
                }.groupedCard()
                Column() {
                  this.actionRow({ title: '仅移除任务，保留文件', action: () => { if (this.selected) { this.confirmDelete(this.selected, false); } } })
                  this.cardDivider()
                  this.actionRow({ title: '删除任务和文件', destructive: true, action: () => { if (this.selected) { this.confirmDelete(this.selected, true); } } })
                }.groupedCard()
              }
            }.padding({ left: 16, right: 16, top: 12, bottom: 24 }).width('100%').enabled(!this.busy)
          }.secondaryScroll()
        } else if (name === 'add') { Scroll(this.pageScroller(name)) { this.addForm() }.secondaryScroll() }
        else if (name === 'detail') {
          if (this.selected) { this.detailPage() }
          else { this.empty('任务已不存在', '任务可能已从服务器中移除。') }
        } else if (name === 'limits') { Scroll(this.pageScroller(name)) { this.limitForm() }.secondaryScroll() }
        else { Scroll(this.pageScroller(name)) { this.preferencesPage(name) }.secondaryScroll() }
      }.width('100%').height('100%')
    }.titleBar({ avoidLayoutSafeArea: true, enableComponentSafeArea: name !== 'detail', style: this.navigationStyle(false, name === 'detail'), content: { divider: { showType: DividerShowType.OFF }, title: { mainTitle: this.pageTitle(name), subTitle: name === 'detail' && this.selected ? this.selected.name : undefined },
        menu: { value: this.destinationMenus(name) },
        bottomBuilder: name === 'detail' && this.selected ? { builder: (): void => this.detailTabs(), height: 44 } : undefined } })
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
      .bindToScrollable(name === 'detail' ? [this.pageScroller('detail-' + this.detailTabSelection.index)] : [this.pageScroller(name)])
      .dynamicHideTitleBar({ hideTitleArea: name === 'detail', hideBottomBuilder: false, hideStatusBar: false,
        mode: HideMode.SCROLL_UP_TO, hideOffset: 16, hideRatio: 2 })
      .backgroundColor($r('sys.color.background_secondary')).onBackPressed(() => this.busy)
      .onDisAppear(() => { if (name === 'server') { this.password = ''; } })
  }
  private destinationMenus(name: string): HdsNavigationMenuItemOptions[] {
    if (name === 'servers') {
      return [{ content: { icon: new SymbolGlyphModifier($r('sys.symbol.plus')), label: '添加服务器', action: () => { this.newServer(); } } }];
    }
    if (name !== 'detail' || !this.selected) { return []; }
    return [
      { content: { label: isStopped(this.selected.state) ? '继续' : '暂停',
        icon: new SymbolGlyphModifier(isStopped(this.selected.state) ? $r('sys.symbol.play_fill') : $r('sys.symbol.pause')), isEnabled: !this.busy,
        action: () => { if (this.selected) { this.operate(isStopped(this.selected.state) ? 'start' : 'stop', [this.selected.hash]); } } } },
      { content: { label: '更多操作', icon: new SymbolGlyphModifier($r('sys.symbol.line_3_horizontal')), action: () => { this.paths.pushPathByName('torrentActions', null); } } },
    ];
  }
  build() {
    HdsNavigation(this.paths) {
      HdsTabs({ barPosition: BarPosition.End, index: this.tab, controller: this.tabsController }) {
        TabContent() { this.taskPage() }.expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
          .tabBar(new BottomTabBarStyle({ normal: new SymbolGlyphModifier($r('sys.symbol.list_bullet')) }, '任务'))
        TabContent() { this.settingsPage() }
          .tabBar(new BottomTabBarStyle({ normal: new SymbolGlyphModifier($r('sys.symbol.gearshape')) }, '设置'))
      }.onChange((index: number) => { this.tab = index; }).barMode(BarMode.Fixed).scrollable(false)
        .barOverlap(true).barFloatingStyle({
          systemMaterialEffect: { materialType: hdsMaterial.MaterialType.ADAPTIVE, materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE }
        })
        .width('100%').height('100%')
    }.titleBar({ avoidLayoutSafeArea: true, enableComponentSafeArea: false, style: this.navigationStyle(this.tab === 0), content: { divider: { showType: DividerShowType.OFF },
      title: { mainTitle: this.selecting && this.tab === 0 ? '选择任务' : this.tab === 0 ? '任务' : '设置',
        subTitle: this.tab === 0 ? (this.selecting ? `已选择 ${this.selection.length} 项` : this.taskScrolled ? undefined : this.activeName) : undefined },
      menu: { value: this.rootMenus() },
      bottomBuilder: this.tab === 0 && this.connected && !this.searching ? { builder: (): void => this.taskSummary(), height: 40 } : undefined
    } }).hideBackButton(true).titleMode(HdsNavigationTitleMode.MINI).mode(NavigationMode.Stack)
      .bindToScrollable(this.tab === 0 ? [this.taskScroller] : [this.settingsScroller])
      .dynamicHideTitleBar({ hideTitleArea: false, hideBottomBuilder: true, hideStatusBar: false, mode: HideMode.SCROLL_UP_TO, hideOffset: 0, hideRatio: 1 })
      .toolbarConfiguration(this.bulkToolbar).hideToolBar(!this.selecting || this.tab !== 0)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
      .navDestination(this.destination).backgroundColor($r('sys.color.background_secondary')).height('100%').width('100%')
  }
}
