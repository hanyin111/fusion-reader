# 视频弹幕

播放器保留现有 media_kit 视频内核，在 Flutter 中绘制弹幕。支持普通播放、全屏、滚动、顶部和底部弹幕，以及开关、透明度、字号、显示区域。弹幕跟随视频时间，暂停与缓冲时停止，倍速和跳转时同步；密集弹幕会跳过占满轨道的内容，避免重叠。

点击播放器的「弹幕设置」可加载 Bilibili XML 或 DPlayer JSON 文件。文件只在本集播放期间使用，切换集数时清除；设置保存到本机。文件和在线响应上限为 8 MB。

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

## 验证与待办

```sh
flutter test test/danmaku_test.dart
flutter test integration_test/video_danmaku_test.dart -d windows
```

Omofun 的实际弹幕接口还未接入。2026-10-10 调查时，电脑网络在 HTTPS 握手阶段被断开，手机流量可以打开网站；尚不能确认是否为出口 IP 风控。不要猜测接口或增加循环重试。网络恢复后，只需读取播放页加载的播放器脚本，核实按作品和集数绑定的弹幕接口、返回格式、时间单位及请求头，再更新独立插件并进行真实播放验证。
