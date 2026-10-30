# 系统代理

应用默认让普通 HTTP 请求跟随操作系统网络设置。Windows 从当前用户的 Internet Settings 读取手动 HTTP 代理；iOS 的自动/代理模式改由 `cupertino_http` 的 Apple URLSession 发送，不再把普通请求交给 Dart socket 并尝试从一个探测 URL 推断代理地址。URLSession 的代理配置保持系统默认，由系统按目标处理代理、PAC、VPN 路由和 DNS；不需要把代理地址写入来源脚本。

Windows 读取本地设置不阻塞应用启动；首个请求等待读取完成，后续请求共用五秒缓存。环境变量 HTTP_PROXY/HTTPS_PROXY 优先于 Windows 系统设置，代理例外及 NO_PROXY 被保留。iOS 普通请求不依赖这份快照，也不强制覆盖系统的代理选择。

Android 和 HarmonyOS 也通过原生桥接读取当前系统 HTTP 代理：Android 使用 `ConnectivityManager.getDefaultProxy()`，HarmonyOS 使用 `connection.getDefaultHttpProxy()`。这包括 VPN 对系统公开的 HTTP 代理；不绑定底层 Wi-Fi 或移动网络，不猜测本地端口。首个请求等待读取完成，HTTP 请求直接连接代理，HTTPS 使用 CONNECT 隧道，域名交由代理解析；已选中的代理连接失败时不会悄悄退回直连。封面、章节缓存、评论、弹幕和播放器可识别的手动代理共用这份设置。

移动代理软件需要向系统公开 HTTP 代理，例如 Clash Mi 的“附加 HTTP 代理到 VPN”。只有 VPN/TUN 且不公开 HTTP 入口时，应用仍遵循系统 VPN 路由；应用无法替另一款软件修改分应用排除、分流规则或选择出口。此接入不等于强制改写 VPN 的全局配置，也不保证通过网站验证。

Android／HarmonyOS 的“设置 → 网络代理”支持手动填写 HTTP 代理地址，供系统未暴露代理入口的环境使用。明确填写的地址优先于环境变量、系统代理及其例外；显式要求直连的来源仍不经过 HTTP 代理。使用兼容环境里的代理时，需要它提供可从原生应用访问的入口；两个环境的 `127.0.0.1` 不应假定互通。设置只保存在本机，不加入 JSON 备份或账号同步。关闭手动代理后恢复系统路由，iOS／Windows 的现有网络实现保持原样。日志中的 `DIRECT` 仅表示未选择 HTTP 代理，不代表流量绕过了系统 VPN。

普通请求、封面和漫画图片、章节缓存、弹幕与 HLS 播放列表使用相同路由。iOS 的仓库下载和应用更新检查也使用 URLSession。视频播放器的媒体连接仍由 libmpv 处理：可识别的手动 HTTP 代理通过 CFNetwork 原生桥接传递，其余 VPN 路由由系统处理；本次不将 libmpv 的传输宣称为 URLSession。iOS WebKit 由系统自行处理代理。独立 gRPC 传输不在本次 HTTP 代理变更范围内。

来源协议已有的 `@network direct`、`@network proxy` 和请求或结果中的 `netMode` 继续有效。显式直连优先于自动跟随，`netMode: 'auto'` 可以恢复自动模式。手动代理地址不上传到同步服务。

Windows 与显式直连使用原有 Dart HTTP 客户端。手动代理解析只接受不带认证的 HTTP CONNECT 地址，不将 PAC、SOCKS 或代理用户名密码错误转换成普通 HTTP 地址。iOS 自动模式交给系统原生传输决定。代理软件的规则仍需允许相应目标连接，使用代理也不保证通过站点验证。

原生传输保留 Dio 的 CookieManager、请求头、流式上传/下载、取消、接收超时和禁止重定向选项，不改变 TLS 证书校验。原生会话不额外持久化 Cookie 或缓存。Info.plist 允许来源提供的普通 HTTP URL，与原先 Dart 客户端可访问的 URL 范围一致；HTTPS 仍由系统正常校验证书。

验证：`flutter test test/apple_http_adapter_test.dart test/network_proxy_test.dart` 使用本机 HTTP 服务与代理，核对请求体、Cookie、二进制和流式数据、取消/关闭/超时、重定向选项以及 Windows 路由回归。`integration_test/system_proxy_test.dart` 在真实 iOS Flutter 引擎中确认生产客户端使用 URLSession，并通过本地服务验证上传、Cookie、重定向、二进制下载、流式读取和取消；也保留播放器使用的原生代理桥接检查。模拟器没有 Shadowrocket/Clash Mi 的真机 VPN 扩展，不能把这些检查当成两款代理软件的实际验证。

图标统一使用 `website/icon.svg` 的书本与播放键设计，运行 `scripts/generate_brand_icons.cjs` 更新 Windows、iOS、Android 和 macOS 的本地图标及引用。
