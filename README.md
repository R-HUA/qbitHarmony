# 下载遥控（qbitHarmony）

面向 HarmonyOS 手机的 qBittorrent 原生管理客户端。根据 [qBitController](https://github.com/Bartuzen/qBitController) 的核心功能重新实现，采用 ArkTS / ArkUI / Stage 模型；不是 Android APK 包装或 WebView。

## 功能

- 多服务器配置、切换、编辑、删除，支持反向代理子路径。
- WebUI 账号密码登录、SID 会话、授权失效后重新登录一次。
- 系统 Asset Store 保存密码；不选择保存时只在当前会话使用。Preferences 不保存密码，SID 不落盘，禁用应用备份。
- 任务列表使用增量同步；前台自动/下拉刷新、关键词和排除词搜索、12 类状态与分类/标签/Tracker 筛选、19 项排序及反转。
- 全局上传/下载速度、累计传输量与速度限制。
- 添加 magnet、HTTP(S) 种子地址或本机 `.torrent` 文件；支持保存路径、分类、标签、重命名、暂停添加、顺序/首尾下载、管理模式和限速。
- 长按多选和批量启停/移除；任务暂停/继续、重新校验、重新汇报、重命名、移动、标签、强制启动、队列优先级和删除。保留文件和永久删除文件是两个独立操作，都有确认弹窗。
- 任务详情包括添加时间、活动/做种时长、传输统计、连接用户及 Tracker。
- 文件目录树、目录聚合进度、目录/多文件选择与批量下载优先级。
- 批量分类、保存路径、标签与队列管理；单任务上传/下载限速、分享率与做种时间规则。
- 鸿蒙系统分享接收文本链接和单个 .torrent 文件；分享磁力链接、通过系统文件选择器导出 .torrent。
- qBittorrent 4.x 的 pause/resume 与 5.x 的 stop/start 自动适配；添加任务的 paused/stopped 参数也按版本处理。

暂不包括：搜索插件、RSS/自动下载规则、云推送、分类/标签的完整增删管理、自签名证书导入、HTTP Basic Auth、qBittorrent 5.2 API Key 登录。

## 本地任务完成通知

在“设置 → 通知”开启任务完成通知并允许系统通知权限，无需服务器桥接或 Push Kit 配置。前台刷新检查当前服务器；后台使用 WorkScheduler 检查已保存服务器。后台需要网络可达和可读取的已保存密码；锁屏时安全资产可能不可读，会跳过本次检查，不降低密码保护级别。

后台申请每两小时检查，但系统可能延后数小时甚至不调度，不能作为实时通知使用。首次开启静默建立基线；超过 24 小时未成功检查会重新建立基线，不补发历史任务。新完成任务按服务器合并，每台服务器最多每分钟发布一次，并更新已有通知；点击完成通知返回对应服务器。

去重状态存入 SQLite，前台与后台共同使用事务避免重复处理。为避免崩溃后重复轰炸，先记录处理结果再发布通知；发布失败或进程在此间退出可能漏掉一次提醒。

平台依据：[延迟任务调度](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/work-scheduler)、[通知授权](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/notification-enable)、[文本通知](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/text-notification)。

## 界面

采用华为 UI Design Kit 的 `HdsNavigation` / `HdsNavDestination`、悬浮 `HdsTabs`、`HdsListItemCard`，系统 Symbol 图标与语义色。底部为“任务 / 设置”，服务器管理收在设置中；启动恢复上次使用的服务器。任务占据页面主体，搜索按需展开，筛选/排序进入标题栏菜单，多选后才显示批量工具。

参考：

- [华为 Navigation 指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-navigation-navigation)
- [华为推荐代码检查规则（字号、热区、无障碍等）](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-coderlinter-recommended-rules)
- [qBittorrent WebUI API](https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-%28qBittorrent-5.0%29)

## 环境与构建

本项目由 DevEco CLI 创建。当前工程使用本机 Command Line Tools 提供的 **26.0.0 SDK / API 26**，最低兼容版本也为 API 26。最终是否匹配目标手机，请以 `devecocli device view` 的实际系统/API 信息为准。

```powershell
$env:DEVECO_CLI_CLT_PATH = 'C:\Program Files\command-line-tools'
devecocli build --modules entry
```

未签名产物通常在 `entry/build/default/outputs/default/entry-default-unsigned.hap`。未签名 HAP 不能直接安装到真机。

真机开启 USB 调试并授权电脑后，在项目根目录执行：

```powershell
devecocli device list
devecocli auth login
devecocli signature generate
devecocli run --module entry
```

仓库不包含个人签名配置，每台电脑需自行签名。签名命令会修改本机 `build-profile.json5`。不要将私钥、证书或包含个人签名路径的配置公开提交；其他电脑应重新生成自己的调试签名。账号登录、实名认证及手机调试授权由设备所有者完成。

## 使用

1. 在 qBittorrent 中启用 WebUI，设置用户名和密码。
2. 手机与服务器网络互通；填写完整地址，例如 `http://192.168.1.10:8080` 或 `https://example.com/qbt`，不要附加 `/api/v2`。
3. 在“设置 → 服务器”中添加配置，可先测试再保存；第一台自动连接。以后启动直接进入上次使用的服务器任务列表。
4. 选择“添加”提交磁力链接、种子下载地址或本机种子文件。

HTTP 不加密传输。外网应使用有效 HTTPS 证书。本应用不关闭 TLS 证书校验，也不自动更改服务器的鉴权、CSRF 或 Host 校验配置。

登录失败不自动反复尝试；变更操作遇到超时不会重放，请刷新列表核实结果后再操作，避免重复提交。

## 测试

```powershell
node --test tests/core.test.cjs tests/torrent-rows.test.cjs
```

测试直接加载生产 API 核心，用内存 HTTP 边界验证请求与错误处理；不访问或修改真实 qBittorrent。测试使用 CLT 自带 TypeScript 转译器，无需安装额外 npm 依赖。

## 目录

```text
entry/src/main/ets/
  core/          纯 TypeScript 数据模型、协议和筛选/格式化逻辑
  services/      HarmonyOS HTTP 与安全资产/偏好设置适配
  pages/         ArkUI 页面和交互
  entryability/  Stage 生命周期，控制前后台刷新
tests/           生产核心逻辑的 Node 测试
```

## 来源与许可

GPL-3.0-only，见 `LICENSE`。此项目不是上游官方 HarmonyOS 版本，不使用上游的图标或应用签名。

参考上游 qBitController 版本：`6d377bde7d09fb96c9ecd9b696b4899c4c28859d`。鸿蒙实现使用 ArkTS/ArkUI，脚手架原有 Huawei Apache-2.0 文件保留各自版权头。
