# 聚阅宣传页

公开地址：<https://reader.hansilver.store/>，由 Cloudflare Pages 托管静态文件。此页面独立于账号同步服务。

双击 `index.html` 也可本地打开。样式、脚本、真实客户端截图与页面图标均内嵌，无外部字体、脚本或图片依赖。`icon.svg` 是同款独立图标源文件，也用于 GitHub README 的图标。

页面顺序：首屏与多端展示 → 小说 / 漫画 / 动画交互展示 → 无广告与阅读排版 → 数据同步与迁移 → 平台下载。

参考 [Matter](https://www.getmatter.com/) 的逐段产品叙述和设备展示，以及 [Aidoku](https://aidoku.app/) 的简洁阅读器定位；未使用其页面代码或图片。

页面配图均来自本地 Windows 客户端运行，直接使用应用原有页面与随包字体，按不同尺寸采集：手机 390×844、平板 1024×768、桌面 1280×800。导出图片为对应逻辑尺寸的 2 倍。没有连接 Android / iOS / 平板硬件，因此不将这些尺寸截图标成相应设备的实机截图。

封面、书名、正文、漫画页面与视频都是占位内容；截图数据使用隔离目录，不读取真实书架。原始 PNG 保留在 `screenshots/`。动画截图的占位弹幕由客户端播放器实际渲染。首屏可切换平板与桌面，点击任意截图放大。阅读样貌按钮切换的是客户端实际采集的字号、明暗截图。

采集工具：`integration_test/promo_capture_test.dart`，显式运行 `flutter test integration_test/promo_capture_test.dart -d windows --no-pub`。未修改应用运行代码或线上数据。

重新采集后运行 `python website/refresh_screenshots.py` 更新内嵌图片。运行 `python website/package_site.py` 将 5 个公开静态文件打包到 `build/private/fusion-reader-site.zip`，在 Cloudflare Pages 的 `fusion-reader-hansilver` 项目创建生产部署并上传。压缩包不包含采集工具、应用源码或私有数据。

下载链接核对于 2026-10-11：Android / iOS / Windows 为 v1.4.3，Linux 为仍公开提供的 v1.4.0；iOS 是未签名 IPA，macOS 尚未提供。发布新版本时更新页面中的版本标签与直接下载链接。

浏览器的减少动态效果设置会关闭动效。页面没有分析统计、追踪或网络接口调用。
