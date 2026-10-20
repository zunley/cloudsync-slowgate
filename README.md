# cloudsync-slowgate

关闭 Synology CloudSync 上传时的 libcurl 低速保护，修复大文件被
`Operation too slow ... 300 seconds` 反复中断、从 0 重传的死循环。

## 现象

CloudSync 通过 WebDAV PUT 上传时，若服务端先收完整个文件、再转传上游云盘，
那么「收完 → 回响应」这一整段对客户端是完全静默的。libcurl 的低速保护
（`CURLOPT_LOW_SPEED_LIMIT=1`、`CURLOPT_LOW_SPEED_TIME=300`）会把这段静默判为传输死亡：

```
[ERROR] webdav-client-handler.cpp(417): Failed to upload file at '...' with error =
'Operation too slow. Less than 1 bytes/sec transferred the last 300 seconds'   (curl 28)
```

随后客户端从 0 重传，下一轮再次在同一点被掐断，形成无限循环。
DSM 与 CloudSync 均未暴露该超时的配置项：UI、`daemon.conf`、配置库、环境变量里都没有。

它是**零进展**上限而非总时长上限——只要字节还在流动，多大的文件都能传完，
所以症状表现为「小文件过、大文件卡」，卡点固定在收完之后的静默期。

## 做法

用 `LD_PRELOAD` 把一个小动态库注入守护进程，拦截 `curl_easy_setopt`，把
`CURLOPT_LOW_SPEED_LIMIT`（19）与 `CURLOPT_LOW_SPEED_TIME`（20）改写为 0——
curl 规定 limit 为 0 时整套低速检查不执行。其余选项按 curl.h 的编码约定原样转发。

只影响被注入的这一个进程；上传速率、上传逻辑、服务端行为都不变。
它不会变快，只是不再被判定死亡。

为什么不能直接 `export LD_PRELOAD`、wrapper 在这条链路里的作用、变参转发为什么必须
知道类型宽度，详见 [docs/how-it-works.md](docs/how-it-works.md)。

## 构建

```bash
make          # 生成 slowgate.so（gcc, x86_64）
make test     # 变参转发自测：19/20 被改写为 0，其余选项原样通过
```

部署到老系统前检查符号版本，`readelf -V slowgate.so` 中的 `GLIBC_*`
不能超过目标机 glibc。

## 部署

需要 root，只影响 CloudSync 一个进程。

```bash
scp slowgate.so <host>:/tmp/
ssh <host> 'sudo bash deploy.sh'
```

`deploy.sh` 依次：真二进制改名为 `syno-cloud-syncd.real` → 原位置写 wrapper →
重启套件 → 检查 `/proc/<pid>/maps` 是否注入成功。

回滚：

```bash
sudo mv /var/packages/CloudSync/target/sbin/syno-cloud-syncd.real \
        /var/packages/CloudSync/target/sbin/syno-cloud-syncd
sudo synopkg restart CloudSync
```

## 验证

1. `/proc/<pid>/maps` 中出现 `slowgate.so`；
2. 日志不再产生新的 `Operation too slow`；
3. 单个 PUT 耗时超过 5m30s 且状态码为 201/204（补丁前必然停在 5m20s/5m30s + 405）。

`watch.sh` 可只读、无 root 地实时观察传输阶段与速率：

```bash
bash watch.sh /path/to/sync/dir 5
```

## 注意

- 语义是**彻底关闭**低速保护。若想留一道保险，改 `slowgate.c` 让 `LOW_SPEED_TIME`
  取有限值（如 1800）再重编即可。
- 套件升级会覆盖 `target/`，wrapper 与库需重新部署。
- 对 `curl_easy_setopt` 的变参转发依赖 curl.h 的选项编码约定，curl 大版本升级时请复查。
