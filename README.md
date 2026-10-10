<p align="center">
  <img src="assets/icon/whitehair-girl-1024.png" width="128" alt="聚阅图标">
</p>

# FusionReader 聚阅

漫画、小说、动画放在同一个书架里。聚阅使用 Flutter 构建，支持在线阅读、本地文件、离线缓存，以及跨设备迁移书架和阅读进度。

[下载正式版](https://github.com/hanyin111/fusion-reader/releases/latest) · [插件网页](https://hanyin111.github.io/fusion-reader-extensions/) · [独立插件项目](https://github.com/hanyin111/fusion-reader-extensions)

## 下载与安装

| 平台 | 发布文件 | 安装方式 |
| --- | --- | --- |
| Android | `FusionReader-版本-android-arm64-v8a.apk` 等 | 常见手机选 arm64-v8a；更新时选择与已安装版本相同的架构 |
| Windows | `FusionReader-版本-windows-x64.zip` | 完整解压后运行 `fusion_reader.exe`，保留同目录的文件 |
| iOS | `FusionReader-ios-unsigned.ipa` | 未签名 IPA，需要自行签名后安装 |
| Linux | `FusionReader-linux-x64.tar.gz` | 解压运行；系统需要 GTK、mpv 和 libsecret，账号凭据存储需要系统 keyring |

macOS 构建暂不发布，修复后再补。历史安装包保留为发布草稿，不占用正式版下载列表。

Android 使用固定签名密钥。之前使用临时签名的旧包无法直接覆盖安装；遇到签名冲突时，先导出书架和历史，再重装并导入。固定签名版本之间可正常更新。

## 插件安装与更新

从 **1.4.0** 开始，应用和来源插件分别发布。本体提供阅读器、书架和脚本运行环境；具体站点的搜索、目录、正文及评论由插件提供。

1. 打开「扩展 → 打开插件仓库 → 填写仓库链接」，手动输入仓库索引地址。应用不内置仓库地址。
2. 保存后选择需要的插件安装。已经手动保存的仓库链接和已安装插件会保留；未填写仓库时，已安装插件仍可使用。
3. 网站接口变化后，在同一页面刷新，点击单个插件的「更新」，或「更新已安装插件」。无需重装应用。
4. 从旧版升级时，先填写仓库链接，再点击「恢复旧版插件」下载原来的来源。书架、历史和插件账号设置继续保留；第一次恢复需要联网。自行安装的脚本继续使用。

插件下载后保存到本机，应用启动不会等待仓库联网。已缓存的章节和目录仍可离线阅读。插件更新会校验文件大小、SHA-256 和脚本信息，失败时保留原插件。应用也保留 URL 和粘贴脚本安装入口。

本项目维护的仓库索引（需要手动填写，也可使用其他兼容仓库）：

```text
https://hanyin111.github.io/fusion-reader-extensions/index.json
```

[插件网页](https://hanyin111.github.io/fusion-reader-extensions/)支持分类、搜索和复制安装链接。分发方式参考 [Mihon](https://github.com/mihonapp/mihon) 和 [Aidoku](https://github.com/Aidoku-Community/sources) 的独立来源仓库；聚阅使用 FusionReader / Miru 格式的 JavaScript 脚本，不直接加载 APK 或 WASM 插件。来源可用性取决于站点和当前网络，具体维护在独立插件项目进行。

## 阅读与数据

- **统一书架与历史**：按漫画、小说、动画筛选；未收藏的作品也会保留浏览历史和阅读进度。
- **小说阅读**：上下滚动或左右翻页，支持字号、字体、章节导航和进度恢复。中间点击打开菜单时，正文位置保持不变；中文衬线字体随应用打包。
- **漫画与动画**：漫画翻页与条漫都支持双指缩放、双击放大或还原，放大后拖动查看；菜单也提供缩放按钮。动画支持 HLS / MP4 播放及进度记忆。
- **离线缓存**：下载章节时一起保存作品详情和完整目录，断网后可进入已下载章节；未下载内容仍需联网。
- **同作者作品与评论**：详情页点击作者进行搜索；支持评论的插件会在目录或阅读器提供入口。章节评论与作品评论分别标注。
- **本地文件**：导入本地书籍、漫画和视频，与在线作品统一管理。

在「设置 → 数据迁移 → 导入与导出」导出 JSON，再在另一台设备导入。导入按来源和作品去重，合并书架、浏览历史及漫画页码、小说位置、视频进度，保留较新的记录。文件包含本系统的阅读设置，同系统换机可恢复字体、排版、背景与阅读模式；其他系统的设置保持原样。文件不包含本地书籍、离线缓存、插件脚本或登录凭据；另一台设备需要安装对应插件。

账号采用一次性激活码注册。在「设置 → 账号与同步」选择 **本地同步云端**（覆盖云端）或 **云端同步本地**（覆盖本机），同步前会提示。删书后先上传，再在其他设备下载。阅读设置可选同步，按系统分别保存，同系统恢复，其他系统的设置继续保留。本地文件和插件账号不上传，退出登录保留本机数据。自建版本需配置同步服务，见 [账号同步说明](docs/account-sync.md)；服务端与独立管理工具分别见 [server](server/README.md) 和 [admin](admin/README.md)。

## 项目结构

```text
fusion-reader/                  应用本体
  lib/pages/                    界面与阅读器
  lib/services/                 书架、插件安装、脚本运行时、网络、账号
  assets/js/runtime.js          插件公共桥接接口
  assets/fonts/                 随包字体
  integration_test/             原生运行时和功能回归
  server/                       可选的 SQLite 同步服务
  admin/                        独立账号管理工具

fusion-reader-extensions/       单独的 GitHub 项目
  sources/                      站点插件脚本
  public/                       GitHub Pages 网页
  tools/                        索引生成与校验
  tests/                        插件业务测试
```

应用不再包含站点插件脚本。iOS / macOS 使用 JavaScriptCore，其余平台使用 QuickJS。插件脚本开发和发布见 [独立项目 README](https://github.com/hanyin111/fusion-reader-extensions#readme)。扩展新的原生能力或修改桥接接口时仍需更新应用本体。

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

Windows 需要 Visual Studio C++、ATL 和 NuGet；Linux 需要 GTK、mpv、libsecret 开发依赖；iOS 需要 Xcode。真实来源的联网集成检查从独立仓库获取脚本，普通测试和 CI 运行时回归使用本地模拟脚本。

GitHub Actions 构建 Android、iOS、Linux，手动运行时可选择 `mobile` 仅构建 Android 和 iOS。Android 发布前检查固定签名、包名、版本及 ABI；iOS 先运行模拟器回归，再生成 IPA。Windows 可本地构建上传，也可使用独立的 Windows 工作流。发布流程确认选定平台的安装包齐全后才公开新版本；只发布手机版时保留上一版桌面端下载，全部平台齐备后再将旧发布改为草稿。应用发布不依赖某个插件仓库在线。macOS 的独立手动工作流保留，暂不参与正式发布。

账号服务地址通过 `FUSION_SYNC_URL` 构建参数注入，Actions 使用同名 Secret。Android 签名使用 `ANDROID_DEBUG_KEYSTORE_B64`，证书指纹保存在 `android/signing-certificate.sha256`；私钥和服务器凭据不提交。未配置同步地址的版本仍可阅读及使用 JSON 迁移。

修改前可运行 `scripts/backup.ps1` 创建本地备份。验证新备份完整后才删除旧备份，只保留最近一份。
