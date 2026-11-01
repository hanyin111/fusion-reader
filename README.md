<p align="center">
  <img src="website/icon.svg" width="128" alt="聚阅图标：打开的书与播放符号">
</p>

# FusionReader 聚阅

漫画、小说、动画放在同一个书架里。聚阅使用 Flutter 构建，支持在线阅读、本地文件、离线缓存，以及跨设备迁移书架和阅读进度。

[聚阅官网](https://reader.hansilver.store/) · [下载正式版](https://github.com/hanyin111/fusion-reader/releases/latest) · [测试预发布](https://github.com/hanyin111/fusion-reader/releases)

## 下载与安装

| 平台 | 发布文件 | 安装方式 |
| --- | --- | --- |
| Android | `FusionReader-版本-android-arm64-v8a.apk` 等 | 常见手机选 arm64-v8a；更新时选择与已安装版本相同的架构 |
| Windows | `FusionReader-版本-windows-x64.zip` | 完整解压后运行 `fusion_reader.exe`，保留同目录的文件 |
| iOS | `FusionReader-ios-unsigned.ipa` | 未签名 IPA，需要自行签名后安装 |
| Linux | `FusionReader-linux-x64.tar.gz` | 解压运行；系统需要 GTK、mpv 和 libsecret |

macOS 测试包通过独立工作流构建，具体可下载的平台以发布页附件为准。历史安装包保留为发布草稿，不占用正式版下载列表。

Android 使用固定签名密钥。之前使用临时签名的旧包无法直接覆盖安装；遇到签名冲突时，先导出书架和历史，再重装并导入。固定签名版本之间可正常更新。

从 1.4.2 起，可在「设置 → 检查更新」查看新版本。Android 和 Windows 支持应用内下载并启动更新，保留书架和阅读记录；iOS 提供 IPA 发布页入口，仍需自行签名安装。首次安装包含更新功能的本体后，后续版本即可通过此入口更新。详见[应用更新说明](docs/app-updates.md)。

## 阅读与数据

- **统一书架与历史**：按漫画、小说、动画筛选；未收藏的作品也会保留浏览历史和阅读进度。
- **小说阅读**：上下滚动或左右翻页，支持字号、字体、章节导航和进度恢复。中间点击打开菜单时，正文位置保持不变；中文衬线字体随应用打包。
- **漫画与动画**：漫画翻页与条漫都支持双指缩放、双击放大或还原，放大后拖动查看；菜单也提供缩放按钮。条漫接近章末时自动加载下一章，继续下滑即可接着阅读，进度按实际阅读的章节保存。Windows 使用鼠标拖动翻页或移动画面，滚轮仅缩放。动画支持 HLS / MP4 播放及进度记忆。
- **离线缓存**：支持全部缓存、按起止章节自定义缓存和单章下载，离开目录页后任务仍会继续。在「设置 → 离线缓存 → 缓存列表」查看进度、取消、重试或管理已下载内容。下载章节时一起保存作品详情和完整目录，断网后可进入已下载章节；未下载内容仍需联网。下载期间请保持应用运行。
- **同作者作品与评论**：详情页点击作者进行搜索；在线来源支持时，目录或阅读器会提供评论入口。章节评论与作品评论分别标注。
- **本地文件**：导入本地书籍、漫画和视频，与在线作品统一管理。
- **视频弹幕**：支持滚动、顶部、底部弹幕，以及字号、透明度和显示区域设置。可加载 XML / JSON 弹幕文件；在线弹幕需要对应内容来源支持。播放器接口与当前接入状态见 [弹幕说明](docs/danmaku.md)。
- **视频播放**：普通与全屏状态均可调整倍速和清晰度，切换时保留进度与暂停状态；退出后保存播放时间，下次从上次位置继续。在线来源支持时，可在详情页和播放器中查看作品评论与回复。

在「设置 → 数据迁移 → 导入与导出」导出 JSON，再在另一台设备导入。导入按来源和作品去重，合并书架、浏览历史及漫画页码、小说位置、视频进度，保留较新的记录。文件包含本系统的阅读设置，同系统换机可恢复字体、排版、背景与阅读模式；其他系统的设置保持原样。文件不包含本地书籍、离线缓存或登录凭据。

## 项目结构

```text
fusion-reader/                  应用本体
  lib/pages/                    界面与阅读器
  lib/services/                 书架、历史、网络与缓存
  assets/fonts/                 随包字体
  integration_test/             原生运行时和功能回归
```

## 开发与发布

使用 Flutter **3.44.2** 或兼容版本，安装目标平台工具链。

```sh
flutter pub get
flutter analyze
flutter test
flutter build windows --release
flutter build apk --release --split-per-abi
flutter build linux --release
flutter build ios --release --no-codesign
```

Windows 需要 Visual Studio C++、ATL 和 NuGet；Linux 需要 GTK、mpv、libsecret 开发依赖；iOS 需要 Xcode。普通测试和 CI 回归使用本地模拟数据。

GitHub Actions 构建 Android、iOS、Linux，手动运行时可选择 `mobile` 仅构建 Android 和 iOS。Android 发布前检查固定签名、包名、版本及 ABI；iOS 先运行模拟器回归，再生成 IPA。Windows、macOS 使用独立工作流。发布流程确认选定平台的安装包齐全后才公开版本；测试预发布保留现有正式版，不触发旧版本归档或正式更新提醒。

Android 签名使用 `ANDROID_DEBUG_KEYSTORE_B64`，证书指纹保存在 `android/signing-certificate.sha256`；签名私钥不提交。

修改前可运行 `scripts/backup.ps1` 创建本地备份。验证新备份完整后才删除旧备份，只保留最近一份。
