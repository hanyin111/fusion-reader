# 来源扫码登录公共协议

应用 1.4.5 起支持来源扫码登录。站点实现和测试由独立来源项目维护；本体只提供界面、桥接与本机凭据存储。

在脚本元数据中声明 `@login qr`，扩展页会显示「来源登录」。发现页加载失败时也提供该入口。二维码由 `qr_flutter` 在本机绘制，无需相机权限或远程二维码制图服务。

## 生命周期

```javascript
async loginStatus() { return { loggedIn: false }; }
async beginLogin() {
  // 创建挑战，将轮询密钥保留在来源实例内。
  return { qrText: 'https://auth.example/scan?challenge=example',
    expiresIn: 180, pollInterval: 3, message: '请使用对应客户端扫码并确认' };
}
async pollLogin() {
  // 确认身份、保存凭据后，才返回 success。
  // waiting / scanned / success / expired / cancelled
  return { status: 'waiting' };
}
async cancelLogin() { /* 使当前挑战作废，阻止迟到响应保存会话。 */ }
async logout() { await this.cancelLogin(); await this.setCredential(null); }
```

已登录时 `loginStatus()` 返回 `{loggedIn:true,username:'显示名称'}`，不返回令牌。客户端限制二维码为 4096 字符、过期时间为 30～600 秒、轮询间隔为 2～15 秒。页面关闭、过期或报错后停止轮询，进入后台时暂停，恢复前台后继续。取消和退出流程须允许重复调用。

`success` 只表示来源已完成凭据保存，不能用于未校验的扫码状态。用户返回后，本体重载来源，刷新发现页。刷新二维码和关闭页面时，来源必须用挑战代次或等价方式忽略旧请求；取消当前挑战不应删除已确认的会话。

## 凭据和响应头

`await this.getCredential()` 返回此来源保存的字符串或 `null`；`await this.setCredential(stringOrNull)` 保存或删除它。最大 16384 字符。键由本体根据已安装来源的包名确定，来源不能通过修改 `this.package` 或传入其他包名读取其他来源或应用账号的凭据。写入完成前会读取核对；失败应保持在登录界面并提示重试。

凭据保存在系统安全存储中，不写入 Hive 来源设置，不参与书架 JSON 导出或云同步。不同设备需要分别授权；卸载来源时清除其本机凭据。插件仍属于用户信任的本地脚本，可以使用自己的凭据发起对应服务请求。

需读取官方认证接口的响应头时，可用：

```javascript
const result = await this.request('https://auth.example/poll', {
  responseMetadata: true, retry: false, timeoutMs: 12000
});
// { body: 原有响应正文, status: 200, headers: { 'set-cookie': ['...'] } }
```

不设置 `responseMetadata` 时仍返回原有正文。Cookie 可来自多条头、合并后的头或服务返回的确认地址，来源应核对域名并仅提取需要的字段。禁止将凭据写入日志、二维码显示文案、错误消息或媒体 CDN 请求头。

## 验证

`flutter test test/extension_login_test.dart test/separate_media_test.dart` 覆盖界面生命周期、轮询并发、错误提示、凭据隔离及音轨模型。`flutter test integration_test/separate_stream_test.dart -d windows` 使用本机合成媒体和虚构认证服务，验证真实 JS 桥接、响应头、凭据包名隔离、分离音视频、压缩弹幕、切换清晰度及离线缓存；需要本机 `ffmpeg`。
