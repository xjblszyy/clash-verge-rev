# IP 上报部署手册

这套功能分两半：

- **VPS 端**跑一个 Port Guardian 服务。它用 iptables 把代理端口对所有人关闭，只放行"上报过"的 IP，这样 GFW 的主动探测连不上你的代理端口。
- **客户端**（Clash Verge）在每次开启连接时，直连请求每台服务器的上报地址。VPS 从请求来源拿到你的 IP，自动加入白名单。

上报地址的格式是 `http://<VPS>:<上报端口>/<代理端口>/<上报路径>`。上报端口和上报路径在所有 VPS 上必须相同，因为客户端只配一组。

## 一、在 VPS 上一键安装

要求：Linux、bash、root 权限、IPv4。支持 Debian/Ubuntu、CentOS/RHEL/Fedora，用 systemd 管理服务。脚本会自动安装 iptables、curl 等依赖，下载 Go 并编译服务，不依赖系统里已有的 Go。

**最简单的方式：直接从客户端复制命令。** 打开 Clash Verge「设置 → 系统设置 → IP 上报」，在「该 VPS 的代理端口」里填这台 VPS 的代理端口。下方会生成带好上报端口和路径的安装命令，点复制按钮，粘贴到 VPS 上执行，然后在客户端点保存。每台 VPS 都这样操作，上报端口和路径会自动保持一致。

也可以手动执行下面的命令。

**第一台 VPS**：把 `443/tcp,8443/udp` 换成你实际的代理端口。

```bash
curl -fsSL https://raw.githubusercontent.com/xjblszyy/clash-verge-rev/dev/docs/ip-report/install.sh | sudo bash -s -- --ports 443/tcp,8443/udp
```

安装完会打印类似下面的内容，**记下上报端口和上报路径**：

```text
Guarded ports : 443/tcp,8443/udp
Clash Verge  > Settings > System > IP Report
  Report Port : 34567
  Report Path : 9f2c7d4e1a8b6c3f0e5d2a7b4c1f8e6d
```

**其余 VPS**：带上第一台生成的端口和路径，保证所有服务器一致。

```bash
curl -fsSL https://raw.githubusercontent.com/xjblszyy/clash-verge-rev/dev/docs/ip-report/install.sh | sudo bash -s -- \
  --ports 443/tcp --http-port 34567 --path 9f2c7d4e1a8b6c3f0e5d2a7b4c1f8e6d
```

> 一键命令从你 fork 的 `dev` 分支下载脚本，所以要先把 `docs/ip-report/install.sh` 推送上去。也可以直接 `scp` 到 VPS 上，再运行 `sudo bash install.sh --ports ...`。
>
> 如果 VPS 访问不了 go.dev，在命令前加 `GO_MIRROR=https://golang.google.cn`，比如 `curl ... | sudo GO_MIRROR=https://golang.google.cn bash -s -- --ports 443`。

### 参数说明

| 参数 | 说明 |
| --- | --- |
| `--ports` | 要保护的代理端口，逗号分隔，写 `端口`、`端口/tcp` 或 `端口/udp`，不写协议默认 tcp。首次安装必填。 |
| `--http-port` | 上报端口。不填时沿用上次的值；首次安装随机取 20000–59999 之间的端口。 |
| `--path` | 上报路径，也就是秘钥。至少 8 位，只能用字母、数字、`-`、`_`。不填时沿用上次的值；首次安装随机生成。 |
| `--force` | 允许保护 sshd 正在监听的端口。一般不要用，否则会把自己挡在外面。 |

### 放行上报端口

脚本检测到 ufw 或 firewalld 在运行时，会自动放行上报端口。**云厂商的安全组**（阿里云、腾讯云、AWS、甲骨文等）脚本改不了，需要你去控制台手动放行这个 TCP 端口。代理端口照常放行，不用改。

## 二、配置客户端

打开 Clash Verge，进入「设置 → 系统设置 → IP 上报」：

1. 打开「启用 IP 上报」。
2. 「上报端口」填安装时打印的 Report Port。
3. 「上报路径」填安装时打印的 Report Path。
4. 保存后立即上报一次。

之后在这些时机会自动上报：内核启动、打开系统代理或 TUN、切换订阅、macOS 网络切换，另外每 10 分钟定时上报一次。客户端会对订阅里的每个节点都尝试上报，不是你 VPS 的节点会失败，客户端会忽略这些失败。

## 三、验证

在你自己的电脑上，**关掉代理后**执行（用安装时打印的那条命令）：

```bash
curl http://<VPS_IP>:34567/443/9f2c7d4e1a8b6c3f0e5d2a7b4c1f8e6d
```

- 返回你的公网 IP：上报成功，这个 IP 已经加白。
- 返回 `Hello, World!`：路径或代理端口不对。**注意**：同一个 IP 错 5 次会被封一小时，别反复试。
- 连接超时：上报端口没放行，检查安全组和防火墙。

在 VPS 上查看规则和日志：

```bash
sudo iptables -S INPUT            # 每个代理端口都有一条 REJECT，加白的 IP 有一条带 clash-verge 注释的 ACCEPT
sudo journalctl -u port-guardian -f   # 看到 "put ip x.x.x.x in port 443/tcp whitelist" 就是加白成功
```

客户端这边可以在日志里搜 `reported`，能看到每台服务器上报成功的记录。

## 四、日常管理

```bash
# 查看当前配置（端口、路径、测试命令）
sudo bash install.sh --show

# 修改保护的端口：重新运行安装并带上新的 --ports，旧端口的规则会自动清掉，路径和上报端口保持不变
sudo bash install.sh --ports 443/tcp,9443/tcp

# 重启服务
sudo systemctl restart port-guardian

# 卸载：停止服务、删除所有相关 iptables 规则、删除程序和配置，代理端口恢复对所有人开放
sudo bash install.sh --uninstall
```

用一键方式时，把上面的 `sudo bash install.sh` 换成 `curl -fsSL <脚本地址> | sudo bash -s --` 即可。

配置文件在 `/etc/port-guardian/guardian.json`，程序在 `/usr/local/bin/port-guardian`，systemd 服务名是 `port-guardian`。

## 五、注意事项

- **只保护 IPv4。** 服务只写 iptables，不写 ip6tables。如果代理同时监听 IPv6，IPv6 那一侧不受保护；节点地址也请用 IPv4，否则上报会失败。
- **同一端口号不能同时保护 tcp 和 udp。** 服务按端口号区分上报地址，重复会冲突，脚本会直接拒绝。
- **重启后需要重新上报。** 服务重启或 VPS 重启后白名单会清空，代理端口先全部拒绝，等客户端下一次上报（重新连接或最多 10 分钟）后恢复。
- **白名单只保留一个 IP。** 每个代理端口只记最后一次上报的 IP，多台设备同时用同一个端口时，后上报的会把前一个挤掉。
- **上报路径是明文传输的。** 上报走的是普通 HTTP，路径在网络上可见。客户端也会把它发给订阅里的其他节点（比如机场节点）。如果路径泄露了，用 `--path` 换一个新的，再同步改客户端设置。
- **端口跳跃。** 节点如果用了 hysteria2 的端口跳跃（`ports` 字段），客户端只按 `port` 字段上报，跳跃范围内的其他端口不会被加白。
- **不要保护 SSH 端口。** 脚本默认会拒绝 22 和 sshd 正在监听的端口。
