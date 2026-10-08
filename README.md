<p align="center">
  <img src="assets/icon/app_icon.svg" width="160" alt="FusionReader">
</p>

# FusionReader 聚阅

漫画 / 小说 / 动画 **三合一聚合阅读器**，使用 Flutter 构建，参考 [Miru Project](https://github.com/miru-project/miru-app) 设计，扩展格式与 Miru 兼容。

## 特性

- 📚 **统一书架** — 漫画、小说、动画收藏在同一个书架，支持按类型筛选、阅读进度记忆
- 🧩 **Miru 兼容 JS 扩展系统** — 扩展是带 `==MiruExtension==` 头部的 JS 脚本，QuickJS 引擎沙箱运行，可从 URL / 粘贴脚本安装新源（兼容 Miru 扩展仓库的 raw 链接）
- 📖 **三种阅读器** — 漫画（翻页 / 条漫双模式、缩放）、小说（字号调节、章节导航）、视频（media_kit，支持 HLS/MP4，全平台硬解）
- ✍️ **同作者作品** — 在小说/漫画详情页点击作者，在当前扩展中查找其他作品；多位作者可分别点击
- 💬 **阅读评论** — 哔哩轻小说支持目录和阅读器内的章节评论；哔咔支持作品评论和回复（各章节共用），可分页、刷新，剧透评论先折叠
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

哔哩轻小说正文加载已于 2026-10-07 更新：使用手机 UA、手机设备参数和真实浏览器会话，先访问目录执行站点脚本，再读取正文并合并章内分页。过滤隐藏重复段落，遇到截断提示会报错，不再把预览保存成完整章节。旧版含截断提示的离线缓存会在阅读时重新拉取。Windows 已实测《Re:从零开始的异世界生活》第一章全部 8 页（29,306 字），插图章 8 张图片及首图下载。

Windows 需要 Microsoft Edge WebView2 运行时。Android、iOS、macOS 已接入浏览器加载，但尚未在实机验证；Linux 暂不支持此源的浏览器正文加载。Windows 和支持代理覆盖的 Android WebView 跟随源的网络路由；iOS、macOS 请使用系统网络，浏览器加载暂不支持应用内自定义代理。自行安装的同名脚本会覆盖内置源，需同步更新为 `assets/extensions/linovelib.js`。

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

# Windows（需 Visual Studio C++ 工具链，nuget.exe 需在 PATH 中）
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

# 哔哩轻小说正文、长章节分页和插图实测（使用独立测试数据）
flutter test integration_test/linovelib_test.dart -d windows

# 旧截断缓存与完整离线缓存回归（独立测试进程）
flutter test integration_test/linovelib_cache_test.dart -d windows

# 离线分页逻辑回归（需 Node.js）
node test/linovelib_test.mjs
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
  async detail(url) { /* -> {title, cover, desc, authors:[{name,id?,url?}], episodes:[{title, urls:[{name,url}]}]} */ }
  async searchAuthor(author, page) { /* 可选：按作者 ID/链接查询，返回 [{title,url,cover}] */ }
  // 声明 @comments chapter 或 @comments work 后可实现只读评论：
  async comments(workUrl, chapterUrl, page, parentId) {
    /* -> {comments:[{id,username,text,time?,likes?,replyCount?,spoiler?,hidden?,pinned?,images?}],hasMore,total?,headers?} */
  }
  async watch(url) {
    // 漫画: {urls:[...], headers?}   小说: {content:[...]}   动画: {type:'hls'|'mp4', url, headers?}
  }
}
```

运行时提供 `this.request` / `querySelector` / `querySelectorAll` / `getAttributeText` / `queryXPath` / `getSetting` 等 Miru 同款 API。

`authors` 是作品作者，区别于扩展头部的开发者 `@author`。内置源使用站点的作者目录或作者筛选；未实现 `searchAuthor` 的旧扩展会调用 `search(author.name, page, {author})`。旧扩展简介开头的 `作者：姓名` / `Author: name` 也兼容点击查询，结果取决于该扩展的搜索能力。

评论默认不启用。扩展头的 `@comments chapter` / `@comments work` 分别表示章节评论和整部作品评论，作品评论在详情页与阅读器中明确标注。当前功能仅查看评论，哔咔沿用扩展设置中的帐号认证；回复查询传入 `parentId`。未更新的同名自装插件会覆盖内置脚本，需同步更新才能显示评论入口。

修改前可运行 `./scripts/backup.ps1 -Label comments`（PowerShell）。脚本保存当前源码及 Windows 程序，完整读取检查新压缩包后再删除旧备份，只保留最近一份；失败时保留旧备份。备份不包含编译缓存或更早的备份文件。

## 架构说明

iOS/macOS 使用 JavaScriptCore，其他平台使用 QuickJS。运行时兼容两种引擎的异步返回值编码，并为每个 Apple 平台扩展单独注册原生回调，避免多个插件之间串线。GitHub Actions 的 iOS 构建会先运行模拟器测试，覆盖全部内置扩展初始化、多插件并发、浏览/搜索、评论、切换和失败重试，再生成未签名 IPA。

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
