# 视频清晰度

普通和全屏播放器顶部均有清晰度菜单。HLS 主播放列表提供多个画质时，本体自动读取分辨率和码率；切换时保留当前播放位置、倍速和暂停状态，弹幕继续跟随播放时间。默认优先最高分辨率，同分辨率优先较高码率。只有一条视频流时显示“原画”，菜单会说明当前视频仅提供一种清晰度，不虚构其他分辨率。

切换画质需要重新缓冲。缓存视频仅播放已下载的版本；本功能不改变缓存任务的画质选择。切换集数后重新读取该集可用画质。

播放进度约每 5 秒保存一次，暂停、切到后台、退出播放器及切换集数时会再保存。重新进入最近观看的那一集时，从保存的时间继续播放；其他集数从开头播放。播放完毕后，下次进入从开头开始。时间戳沿用历史记录中的毫秒位置，已有 JSON 导入导出和历史同步可以一起携带，无需变更服务端格式。

## 公共返回协议

原有 `watch()` 的 `type`、`url`、`headers`、`netMode`、`danmaku` 字段继续有效。普通 HLS 主列表无需增加接口；若有多个独立视频地址，可额外返回 `qualities`：

```javascript
return {
  type: 'mp4',
  url: 'https://video.example/episode-1080.mp4',
  headers: { Referer: 'https://reader.example/' },
  qualities: [
    { label: '1080P', url: 'https://video.example/episode-1080.mp4' },
    { label: '720P', url: 'https://video.example/episode-720.mp4' }
  ]
};
```

每项还可覆盖 `type`、`headers`、`netMode`；未填写时继承顶层，HTTP 请求头按名称忽略大小写合并。`qualities` 仅接受 HTTP/HTTPS 地址。顶层仍应提供旧客户端可播放的 `url`。具体站点脚本由独立来源项目维护。

1.4.5 起支持独立音轨：顶层 `watch()` 和每个 `qualities` 项均可返回 `audioUrl`，视频地址仍在 `url`。每个不同的视频地址应同时指定对应音轨，避免切换画质时沿用错误音频；没有独立音频时省略该字段。音视频地址只接受 HTTP/HTTPS，本体通过本地 [mpv EDL](https://github.com/mpv-player/mpv/blob/master/DOCS/edl-mpv.rst) 合并播放，切换时继续保留进度、倍速和暂停状态。缓存会同时下载视频、音轨并写入本地播放列表，之后可离线播放。

HLS 处理保留加密密钥、初始化分片、签名查询参数和当前画质引用的音轨／字幕组，按响应最终地址解析相对路径。协议依据 [RFC 8216](https://datatracker.ietf.org/doc/html/rfc8216)。播放器状态恢复使用 [media_kit](https://github.com/media-kit/media-kit) 的 `Media.start`、`Player.open(play:)` 和 `setRate`。

## 本地验证

```sh
flutter test test/video_quality_test.dart test/video_quality_button_test.dart test/video_progress_test.dart
flutter test integration_test/video_quality_test.dart -d windows
flutter test integration_test/video_danmaku_test.dart -d windows
```

测试使用本地合成视频和模拟播放列表，不访问第三方内容站点。清晰度原生集成测试需要本机 `ffmpeg` 命令，用于生成两个分辨率的短片和独立音轨；覆盖普通／全屏切换、位置、倍速、暂停状态与请求头。
