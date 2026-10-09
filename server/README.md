# 聚阅账号同步服务

轻量 WSGI 服务，业务代码只依赖 Python 标准库，数据库为 SQLite 单文件。生产环境使用 Gunicorn 与 HTTPS 反代。支持激活码注册、登录、退出和书架/历史快照；管理操作仅通过服务器 SSH 命令完成，没有公网管理员接口。

本文使用示例域名，不能直接作为正式配置使用。真实部署地址由维护者私下设置，源码及构建日志不应包含服务器 IP、域名、密码、私钥、激活码或用户数据。

## 部署

要求 Linux、Python 3.10+ 和 hashlib.scrypt 支持。先检查资源余量和已有端口，不要停止其他服务。代码建议放 /opt/fusion-reader-sync；使用独立 fusion-sync 用户、虚拟环境及 /var/lib/fusion-reader-sync/library.sqlite3，目录权限 700、文件权限 600。

```sh
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
FUSION_SYNC_DB=/var/lib/fusion-reader-sync/library.sqlite3 \
  .venv/bin/gunicorn --workers 1 --threads 2 --worker-class gthread \
  --bind 127.0.0.1:18765 --timeout 30 'sync_server:create_app()'
```

fusion-reader-sync.service 提供 systemd 模板。保持一个 worker；轻量限流器在单进程共享。单次密码哈希工作内存约 32 MiB，解析较大快照时另需内存。用 GET http://127.0.0.1:18765/health 验证回环服务。

nginx-sync.conf 为示例反代配置，部署前替换示例域名并签发有效证书。请求体最多 21 MiB，缓冲请求体并设置超时，访问日志关闭；反代覆盖 X-Real-IP，不要透传用户输入。只有设置受信任的回环代理时，应用才读取该头。证书应配置自动续期并实际验证重载钩子。

## 独立管理程序

见 [桌面管理程序](../admin/README.md)。管理员通过 SSH 连接，然后使用固定命令将 JSON 请求从标准输入传入；密码、原始激活码不在命令参数中出现。

```sh
printf '%s' '{"action":"users.list"}' | \
  /opt/fusion-reader-sync/.venv/bin/python \
  /opt/fusion-reader-sync/sync_server.py \
  --db /var/lib/fusion-reader-sync/library.sqlite3 admin
```

SSH 用户必须能运行程序并读写数据库。私有管理命令支持批量生成激活码、分页状态列表、粘贴原码查询、撤销未使用激活码、用户统计、禁用/启用、退出全部设备及重置密码。禁用和重置密码立即撤销该用户的全部会话，保留书架和历史。没有自动删除真实用户的操作。

新激活码原码只在生成当次返回，数据库仅存 SHA-256 哈希，无法恢复旧原码。列表使用随机管理编号；旧库的激活码生成时间未记录，因此显示未知。状态优先顺序为已使用、已撤销、已过期、未使用。

旧版终端命令仍可使用：

```sh
sudo -u fusion-sync /opt/fusion-reader-sync/.venv/bin/python \
  /opt/fusion-reader-sync/sync_server.py \
  --db /var/lib/fusion-reader-sync/library.sqlite3 invite --count 5 --days 30
```

每个激活码可注册一次。创建账号和消费激活码在同一事务内；用户名冲突会回滚。密码使用独立随机盐的 scrypt 哈希，会话令牌仅存哈希，默认有效期 30 天、每账号最多十个会话。

## 数据迁移与备份

数据库 schema v2 在一个 SQLite 写事务内给用户添加禁用状态、给激活码添加编号/生成时间/撤销时间；保留全部旧密码哈希、激活码哈希、用户、会话与快照，重复启动不会再次修改编号。库版本由 PRAGMA user_version 管理，拒绝无关已有数据库和不支持的版本。客户端 JSON 格式仍为 schema 1。

每账号保存最新快照。PUT /v1/library 按版本号条件写入，冲突返回 409；方向和覆盖规则由客户端决定。接口契约见 [账号同步说明](../docs/account-sync.md)。

不要运行时只复制 SQLite 主文件，因为 WAL 可能尚未检查点。先用内置一致备份命令生成新副本，验证后替换上一份备份；同时保留迁移前的一份服务代码。两者不得提交仓库。

```sh
python sync_server.py --db /var/lib/fusion-reader-sync/library.sqlite3 \
  backup /var/lib/fusion-reader-sync/library.previous.sqlite3
```

备份命令要求目标不存在，保护权限为 600。不要将 v1 代码直接配上已迁移的 v2 数据库回滚；恢复时必须同时恢复迁移前的数据库和代码。

## 验证

```sh
python -m unittest discover -s server -p 'test_*.py' -v
```

测试覆盖旧库迁移、原接口回归、激活码状态、并发版本冲突、禁用与密码重置的会话失效、快照保留、输入验证和无公网管理入口。test_fixture.py 的 wsgiref 服务器仅供回环联调，不用于生产部署。
