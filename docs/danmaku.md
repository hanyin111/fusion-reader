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

## 播放器验证

本体测试使用本地占位视频与模拟弹幕，覆盖时间同步、暂停恢复、倍速、进度跳转，以及全屏控制栏和评论导航。普通 CI 不自动访问第三方站点。具体站点的接入状态、脚本版本与接口验证由独立来源项目记录。

```sh
flutter test test/danmaku_test.dart test/danmaku_session_test.dart test/extension_grpc_test.dart
flutter test integration_test/video_danmaku_test.dart -d windows
```
