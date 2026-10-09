# 聚阅 · 账号管理

独立 Windows 桌面程序，通过 SSH 管理账号同步服务。无需给服务器增加管理员网页或公网管理端口；程序没有内置服务器地址、密码、私钥或激活码，也不会自动保存登录密码。

## 使用

打开 `FusionReader-Admin.exe`，填写服务器 IP/域名、SSH 端口和用户名，然后填写密码或选择本地 SSH 私钥。私钥若有口令，在密码栏填写。首次连接会显示服务器 SSH 指纹，核对后确认；以后若指纹不同，程序停止连接。已信任的指纹保存在本机用户目录下的 `FusionReaderAdmin/known_hosts`，也会读取系统 OpenSSH 的 known_hosts。

连接方式默认“跟随系统代理”，Windows 下直接读取系统已开启的 HTTP 代理，不要求开启 TUN。也可以选择“手动代理”，填写本机 HTTP / 混合代理的地址和端口（例如 `127.0.0.1`、`7890`；以你的代理软件设置为准），或选择“直连”。代理通过 HTTP CONNECT 转发 SSH，服务器指纹校验和 SSH 加密保持生效；代理失败不会自动回退直连。仅有 PAC 自动代理脚本或 SOCKS 入口的系统配置，需要手动指定 HTTP / 混合端口。地址、端口和密码均不自动保存。

“激活码”页可批量生成并直接入库、查看未使用/已使用/过期/撤销状态和使用用户名、查询已有原码，以及撤销未使用激活码。列表中的管理编号不是激活码。新原码仅在本次会话中显示，可复制或导出 CSV；断开/退出后不会自动恢复，务必妥善保管导出文件。生成超时后先刷新列表确认，避免重复生成。

“用户管理”页可查看注册时间、账号状态、书架与历史条数、有效登录数及云端版本；可禁用/启用、退出全部设备或重置密码。影响账号的操作需界面确认。禁用和重置密码会让全部设备重新登录，保留书架/历史；程序不提供永久删除用户按钮。

管理操作要求 SSH 用户具有 `/opt/fusion-reader-sync` 的执行权限及数据库读写权限；以 root 连接时，固定命令会使用 `fusion-sync` 服务用户操作，保持 SQLite WAL 文件权限一致。服务端需要包含 `admin_commands.py` 和数据库 v2 管理扩展。所有敏感输入通过 SSH 的标准输入传输，不出现在服务器进程参数中；错误对话框不输出原始日志或凭据。SSH 主机名只用于当前连接和本机已信任指纹记录。

## 开发及打包

Python 3.10+，Windows 桌面环境带 Tkinter：

```powershell
python -m pip install -r admin/requirements.txt
python admin/manager.py
./scripts/build_admin.ps1
```

脚本创建隔离依赖环境，先运行管理客户端测试，再生成 `build/admin/FusionReader-Admin.exe`；不要求使用者安装 Python。`build/` 已忽略，不会提交编译文件和本地配置。

依赖使用 [Paramiko](https://docs.paramiko.org/en/stable/api/client.html) 的 SSH 客户端和 [PyInstaller](https://pyinstaller.org/en/stable/) 打包。测试覆盖主机指纹确认、敏感信息只经标准输入、错误脱敏、空默认服务器配置和中文表格。服务端业务测试从仓库根目录运行 `python -m unittest discover -s server -p 'test_*.py'`。
