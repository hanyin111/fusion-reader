# 视频弹幕

播放器保留现有 media_kit 视频内核，在 Flutter 中绘制弹幕。支持普通播放、全屏、滚动、顶部和底部弹幕，以及开关、透明度、字号、显示区域。弹幕跟随视频时间，暂停与缓冲时停止，倍速和跳转时同步；密集弹幕会跳过占满轨道的内容，避免重叠。

点击播放器的「弹幕设置」可加载 Bilibili XML 或 DPlayer JSON 文件。文件只在本集播放期间使用，切换集数时清除；设置保存到本机。文件和在线响应上限为 8 MB。

普通和全屏播放均可点击顶部倍速数字调整速度，所选速度随集数切换保留。支持评论的插件会显示评论按钮；查看评论时视频暂停，返回后恢复打开评论前的播放状态，并保留全屏。

## 插件接口

从 1.4.2 开始，动画插件的 `watch(url)` 可以附带可选的 `danmaku` 字段。弹幕独立加载，失败不会中断视频。旧客户端忽略这个字段，仍可播放视频；来源地址仍由独立插件维护，本体不内置站点弹幕接口。

```javascript
return {
  type: 'mp4',
  url: 'https://video.example/episode.mp4',
  headers: { Referer: 'https://anime.example/' },
  danmaku: {
    url: 'https://comments.example/v3/?id=episode-1',
    format: 'dplayer', // 或 bilibili
    headers: { Referer: 'https://anime.example/' },
    // 可选：netMode: 'direct'
  }
};
```

DPlayer 格式为 `{ "code": 0, "data": [[秒数, 类型, RGB整数, 用户, 文本]] }`，类型 0 为滚动、1 为顶部、2 为底部。Bilibili XML 的 `d` 元素按 `p` 属性读取秒数、模式和颜色，支持模式 1/2/3、4、5；不执行特殊或脚本弹幕。

渲染和时间同步思路参考 [DanDanPlayForAndroid](https://github.com/xyoye/DanDanPlayForAndroid/tree/master/player_component/src/main/java/com/xyoye/player/controller/danmu)，本实现为独立编写的 Dart 代码，没有引入其 Android 播放器或复制其源码。DPlayer 数据约定参考其[官方后端适配](https://github.com/DIYgod/DPlayer/blob/master/src/js/api.js)。

## 按播放进度加载

插件也可返回 `danmaku: {format: 'extension', url: '作品:集数', windowSeconds: 180}`，并实现 `async danmaku(url, fromSeconds, toSeconds)`，返回上述 DPlayer 数组。`url` 是传给插件的标识；时间范围单位为秒。播放器预取接下来约 3 分钟的数据，按视频进度继续加载，拖动进度条时读取对应范围；重叠数据去重，最多缓存 12 个窗口，切换章节和导入本地文件会清除旧请求的结果。网络失败不会影响视频，自动重试间隔至少 30 秒。

脚本可使用 `await this.grpcRequest({endpoint, method, data, metadata, certificate})` 调用 TLS gRPC 的一元接口。`data` 和返回值为 protobuf 字节的 Base64；具体服务名和消息编码由插件实现，本体不内置站点地址。每次请求限时 10 秒，响应上限 8 MB。默认使用系统证书验证；若插件提供 PEM 证书，则证书错误只能通过该证书的精确 SHA-256 校验，其他证书仍会被拒绝。

## Omofun 接入与验证

2026-10-10 对用户提供的官方桌面 App 2.0.1 做只读分析，并实测其公开的分类、搜索、作品详情、播放地址、弹幕读取接口。读取这些接口无需账号令牌或请求签名；没有使用登录数据，也没有提取或分发共享签名密钥。网站打不开时 App 仍可用，符合其独立接口的实际测试结果；网页 TLS 失败的具体原因仍无法确认。

独立插件 Omofun v1.1.1 使用 App 接口，需应用 1.4.2 或更新版本提供 gRPC 桥接。旧书架可按完整标题唯一匹配作品；有同名歧义时提示重新搜索，避免错误绑定。播放线路若需要官方 App 专用加速组件，会明确提示切换其他线路。作品评论及回复也使用无需登录的公开读取接口，详情页和播放器提供入口，各集共享作品评论。

Windows 真实运行时验证了分类、两页列表、搜索、目录、天堂线路的原生视频读取、同一集两个时间范围的弹幕，以及作品评论的两页分页和回复。全屏操作测试覆盖倍速选择、控制栏再次显示、评论导航和暂停恢复。普通 CI 使用本地模拟服务，不自动访问第三方站点；安卓与 iOS 仍需原生构建和设备测试。

```sh
flutter test test/danmaku_test.dart test/danmaku_session_test.dart test/extension_grpc_test.dart
flutter test integration_test/video_danmaku_test.dart -d windows
# 实际接口检查仅在明确传入本地插件脚本时运行：
flutter test integration_test/omofun_app_test.dart -d windows --dart-define=OMOFUN_SCRIPT=/absolute/path/omofun.js
```
