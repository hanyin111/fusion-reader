# FusionReader 聚阅

漫画 / 小说 / 动画 **三合一聚合阅读器**，使用 Flutter 构建，参考 [Miru Project](https://github.com/miru-project/miru-app) 设计，扩展格式与 Miru 兼容。

## 特性

- 📚 **统一书架** — 漫画、小说、动画收藏在同一个书架，支持按类型筛选、阅读进度记忆
- 🧩 **Miru 兼容 JS 扩展系统** — 扩展是带 `==MiruExtension==` 头部的 JS 脚本，QuickJS 引擎沙箱运行，可从 URL / 粘贴脚本安装新源（兼容 Miru 扩展仓库的 raw 链接）
- 📖 **三种阅读器** — 漫画（翻页 / 条漫双模式、缩放）、小说（字号调节、章节导航）、视频（media_kit，支持 HLS/MP4，全平台硬解）
- 🌐 **内置 8 个源**，其中每个类目至少 2 个经过真实联网验证可用
- 💻 **全平台** — Windows / Android / iOS / macOS / Linux

## 内置源状态（2026-07 实测，系统代理 Clash 环境下）

| 类目 | 源 | 状态 | 路由 | 实测结果 |
|---|---|---|---|---|
| 漫画 | MangaDex | ✅ | 跟随全局 | 827 话，首页图片实测下载 1055KB |
| 漫画 | WeebCentral | ✅ | 跟随全局 | Naruto 701 话完整，图片 307KB |
| 漫画 | 哔咔漫画 | ⚙️ | 跟随全局 | 签名链路已验证，需在扩展设置填自己的帐号 |
| 小说 | ESJ Zone | ✅ | 跟随全局 | 40 本/页，45 章，正文 6190 字（登录已实测：真实账号登录成功，「我的收藏」频道可拉取账号收藏；无封面，站点封面为JS注入） |
| 小说 | Project Gutenberg | ✅ | 跟随全局 | 全文 55.6 万字 |
| 小说 | Royal Road | ✅ | 跟随全局 | 109 章，正文 4.2 万字 |
| 小说 | 哔哩轻小说 | ⚠️ | 跟随全局 | 浏览/详情/正文可用；搜索被 JS 守卫拦截，降级为榜单内标题匹配 |
| 动画 | 樱花动漫 (yhdm.one) | ✅ | 混合 | **实测起播 49ms**，8 条线路自动探测，13 个分类频道 |
| 动画 | Internet Archive | ✅ | 跟随全局 | **实测起播 39ms** |

> 「实测起播」指测试真的把流解码出了画面（position > 0），而不只是拿到了 URL。
> 所有源可在「扩展」页随时启用/禁用并单独切换网络路由。

### 网络路由（重要）

源站点对网络出口的要求是相反的：国内站点会拒绝境外代理出口，被墙站点则必须走代理。所以路由是**按源**、甚至**按请求**决定的：

- 扩展头 `@network direct|proxy|auto` 声明源的默认路由
- 「扩展」页每个源可手动覆盖为 跟随全局 / 强制直连 / 强制代理
- 扩展内 `this.request(url, { netMode: 'direct' })` 可为单个请求指定路由
- `watch()` 返回 `netMode` 可让**播放/图片下载**走与网页抓取不同的路由

樱花动漫就是混合案例：网页 HTML 走代理，视频 CDN 直连——封面图、m3u8 探测、mpv 播放三者会各自使用正确的出口。

## 构建

前置：Flutter 3.44+（stable channel）。

```bash
flutter pub get

# Windows（需 Visual Studio C++ 工具链）
flutter build windows --release

# Android（需 Android SDK）
flutter build apk --release --split-per-abi

# Linux（需 ninja-build libgtk-3-dev libmpv-dev）
flutter build linux --release

# macOS / iOS（需 Xcode）
flutter build macos --release
flutter build ios --release --no-codesign
```

或推送 `v*` 标签 / 手动触发 GitHub Actions（`.github/workflows/build.yml`），自动构建全部 5 个平台的产物。

## 源验证测试

```bash
flutter test integration_test/sources_test.dart -d windows
```

对每个已启用扩展真实联网跑 `latest → search → detail → watch` 全链路，并断言漫画/小说/动画每类至少 2 个源可用。

## 扩展开发

扩展是单个 `.js` 文件（与 Miru 格式一致）：

```js
// ==MiruExtension==
// @name         MySource
// @package      mysource
// @version      v1.0.0
// @type         manga        // manga | fikushon(小说) | bangumi(动画)
// @webSite      https://example.com
// ==/MiruExtension==

export default class extends Extension {
  async latest(page) { /* -> [{title, url, cover}] */ }
  async search(kw, page) { /* -> [{title, url, cover}] */ }
  async detail(url) { /* -> {title, cover, desc, episodes:[{title, urls:[{name,url}]}]} */ }
  async watch(url) {
    // 漫画: {urls:[...], headers?}   小说: {content:[...]}   动画: {type:'hls'|'mp4', url, headers?}
  }
}
```

运行时提供 `this.request` / `querySelector` / `querySelectorAll` / `getAttributeText` / `queryXPath` / `getSetting` 等 Miru 同款 API。

## 架构说明

Mihon 插件是 Android APK（Dalvik 字节码），技术上无法在 Windows/iOS 等平台加载，因此本项目与 Miru 一样采用跨平台 JS 扩展方案，并保持与 Miru 扩展格式互通。

```
lib/
  models/           数据模型（MediaItem、MediaDetail、Watch 结果等）
  services/
    extension_runtime.dart   QuickJS 运行时 + Dart 桥（网络/HTML解析/设置）
    extension_manager.dart   扩展加载、安装、启停
    storage.dart             Hive 存储（书架/历史/设置）
    network.dart             dio + 代理
  pages/            书架 / 发现 / 详情 / 三种阅读器 / 扩展管理 / 设置
assets/
  js/runtime.js     JS 侧 Extension 基类与异步桥
  extensions/*.js   内置扩展源
```
