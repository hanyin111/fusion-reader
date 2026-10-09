# 账号与手动同步

入口在「设置 → 账号与同步」。使用用户名、密码和一次性激活码注册。登录后选择「本地同步云端」或「云端同步本地」，覆盖前会提示影响。注册、登录不会自动同步。

同步内容是在线作品的书架、浏览历史、章节和阅读位置（包括小说翻页偏移）。本地导入文件、离线缓存、插件账号和应用设置不上传。JSON 导入导出继续可用，导出不包含账号登录凭据。

「本地同步云端」把本机当前的书架、历史和进度完整上传并覆盖云端，不写回本机。「云端同步本地」完整下载并覆盖本机的网络作品记录，不修改云端。两者均不自动合并，空列表也会覆盖。删书后先上传，再在其他设备下载，可以避免旧记录自动恢复。

上传使用版本号条件更新，遇到另一台设备同时更新则停止并提示重新确认，不静默重试覆盖。上传失败不修改本机；上传期间的新阅读记录仍保留在本机，下一次上传才会包含它们。下载失败或云端数据验证失败不改本机；下载过程中本机记录发生变化则停止，避免覆盖新操作。覆盖前建议先用 JSON 导出备份。退出账号保留本机数据。

密码和激活码只用于本次请求，不保存；登录令牌由系统安全存储保存。Android 的安全存储不随系统备份迁移，iOS 使用本机 Keychain；Linux 需要可用的 Secret Service/keyring。账号功能初始化失败不会阻止正常阅读。

## 服务地址

服务地址通过构建参数 `FUSION_SYNC_URL` 注入，必须是 HTTPS。源码不包含真实域名或服务器 IP。参数为空或无效时页面明确显示未配置并禁用注册、登录按钮。没有新增用户网络配置选项。

```powershell
flutter build windows --release --dart-define=FUSION_SYNC_URL=https://sync.example.com
```

GitHub Actions 读取同名仓库 Secret，并传给 Android、iOS、Linux、macOS 构建。安装包必须包含联网域名，构建 Secret 只能避免源码、文档和构建日志直接暴露地址，不能让客户端域名不可提取。客户端使用独立连接，检查 TLS 证书、不接受重定向，不复用插件网络的证书或代理策略。

## REST 接口契约

所有响应为 JSON，除注册和登录外均需 `Authorization: Bearer <token>`。错误只返回稳定错误标识，客户端不显示原始服务日志。

| 方法与路径 | 请求 | 成功响应 |
| --- | --- | --- |
| `POST /v1/auth/register` | `username`、`password`、`activationCode` | 登录会话，201 |
| `POST /v1/auth/login` | `username`、`password` | 登录会话，200 |
| `POST /v1/auth/logout` | 无 | `{"ok":true}`，200 |
| `GET /v1/library` | 无 | `{"revision":0,"snapshot":…}`，200 |
| `PUT /v1/library` | `expectedRevision`、`snapshot` | `{"revision":1}`，200 |

登录会话为 `{"user":{"id":"<opaque-id>","username":"reader"},"token":"<random-base64url>","expiresAt":"<UTC ISO8601>"}`。用户名规范化为小写，3–32 位 ASCII 字母、数字或下划线；密码 8–128 个字符。激活码必须由服务端原子消费，同一码不能注册两次。

`snapshot` 与已有 `FusionReader.library` schemaVersion 1 JSON 一致，最高 20 MiB / 50000 条作品与历史记录。新账号返回有效的空快照。PUT 必须以数据库条件更新检查版本，冲突返回 409，不覆盖更新较新的快照。版本从 0 开始，每次成功上传递增 1。

错误格式为 `{"error":"<code>"}`：`invalid_activation_code`（403）、`username_taken`（409）、`invalid_credentials`（401）、`invalid_input`（400）、`payload_too_large`（413）、`rate_limited`（429）。带令牌请求的 401 代表登录已失效。

## 验证与管理

测试覆盖明确方向覆盖、删书后上传和下载、空列表覆盖、上传冲突、网络失败、下载期间本机修改、账号隔离、原生安全存储失败和注册校验。两个实际 Flutter 客户端与临时 SQLite HTTP 服务也验证了完整流程。原生令牌存储由 `integration_test/account_storage_test.dart` 检查。

独立管理程序通过 SSH 执行服务器管理命令，见 `admin/`。管理端不提供公网 API，服务器凭据、激活码原文和用户数据不提交仓库。服务端备份与维护见 `server/README.md`。
