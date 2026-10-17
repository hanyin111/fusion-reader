# 系统代理

应用默认让普通 HTTP 请求跟随操作系统已配置的 HTTP 代理。Windows 从当前用户的 Internet Settings 读取，iOS 通过 CFNetwork 读取并用原生桥接交给 Dart；不需要把代理地址写入来源脚本。没有可用 HTTP 代理时使用系统网络，系统 VPN/TUN 的分流仍由对应软件控制。

读取本地设置不阻塞应用启动；首个请求等待读取完成，后续请求共用五秒缓存，代理开关或端口变化在后续请求中生效。环境变量 HTTP_PROXY/HTTPS_PROXY 优先于系统设置。Windows 的代理例外及 NO_PROXY 被保留。

普通请求、封面和漫画图片、章节缓存、弹幕与 HLS 播放列表使用相同路由。播放器打开网络媒体前应用同一路由；iOS WebKit 由系统自行处理代理。独立 gRPC 传输不在本次 HTTP 代理变更范围内。

来源协议已有的 `@network direct`、`@network proxy` 和请求或结果中的 `netMode` 继续有效。显式直连优先于自动跟随，`netMode: 'auto'` 可以恢复跟随系统。无新增应用内网络配置页，不保存或上传代理地址。

本次支持不带认证的 HTTP CONNECT 代理及原有系统 VPN/TUN 网络。PAC、SOCKS 和代理用户名密码不转换成普通 HTTP 代理；它们不是本次显式代理覆盖的支持范围。代理软件的规则仍需允许相应目标连接，使用代理也不保证通过站点验证。

验证：`flutter test test/network_proxy_test.dart` 使用本机 HTTP 服务与代理，核对首次并发请求、HTTPS CONNECT、直连覆盖、图片和弹幕、代理切换、例外及环境变量优先级。iOS 原生桥接在 `integration_test/system_proxy_test.dart` 检查，需 macOS/iOS 构建环境；Windows 本机不能替代 Shadowrocket 真机测试。

图标统一使用 `website/icon.svg` 的书本与播放键设计，运行 `scripts/generate_brand_icons.cjs` 更新 Windows、iOS、Android 和 macOS 的本地图标及引用。
