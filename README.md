# rc06-wireguard

**在小米 BE7000 / RC06 等高通 IPQ 魔改内核路由器的 Docker 里跑 WireGuard 服务端——不需要内核模块,不需要拆机刷机。**

> English TL;DR: Run a WireGuard server in Docker on Xiaomi routers with vendor-patched 5.4 kernels (IPQ807x era) where the WireGuard kernel module is absent and cannot be installed. This repo ships a userspace `wireguard-go` build with a one-line fix (`IFF_VNET_HDR` removed) — without it, the vendor tun driver silently drops all userspace TUN writes and the VPN data plane is dead while handshakes look perfectly healthy. See [docs/story.md](docs/story.md) for the full debugging saga.

## 为什么需要这个项目

在这类机器上(实测: RC06/BE7000 同平台, 固件 1.1.38, 内核 5.4.64x aarch64):

| 障碍 | 现象 |
|------|------|
| 内核无 wireguard 模块, 固件无 opkg | 内核态方案全部出局 |
| 新版 wireguard-go 硬编码 `IFF_VNET_HDR` | **握手正常但数据面全死**: 解密后的包写入 TUN 被厂商 tun 驱动静默丢弃 (RX 恒 0, 无任何报错) |
| Docker bridge + userland docker-proxy | UDP 中继丢握手响应, 客户端无限重握手 |
| 容器内 iptables 为 nft 后端 | 内核无 nf_tables, PostUp 规则必失败 |
| 小米 `opa-docker-authz` 插件 | 默认拒绝一切 `CapAdd`, WireGuard 所需的 `NET_ADMIN` 被拦 |

## 解法 (三层, 全部在本仓库)

1. **去 vnet 头的 wireguard-go**: 对上游 v0.0.20250522 打一行补丁 (见 [patches/](patches/)), 交叉编译 linux/arm64。预编译二进制在 [prebuilt/](prebuilt/), 也可自行构建 (见 [build-wireguard-go.sh](build-wireguard-go.sh))
2. **host 网络容器**: 跳过 docker-proxy 层, :51820/udp 直接监听宿主机
3. **宿主机侧 NAT/FORWARD**: 容器内 iptables 置空 (`PostUp = no-op`), MASQUERADE 与转发放行在宿主机完成, 由 cron 每分钟自愈

## 快速开始 (在路由器上)

前提: 已通过任意方式开启 SSH (如 [xmir-patcher](https://github.com/openwrt-xiaomi/xmir-patcher)), Docker 插件已启用, USB 存储挂载于 `/mnt/usb-xxx`。

```sh
# 1. 克隆本仓库到 USB
cd /mnt/usb-xxx
git clone https://github.com/<you>/rc06-wireguard.git wireguard
cd wireguard

# 2. 放宽 authz 策略 (仅允许 NET_ADMIN, tmpfs 重启自动还原)
#    详细说明见 recreate-wireguard.example.sh 第 1 步

# 3. 构建专属镜像并启动
docker build -t rc06-wireguard:1.0 .
docker run -d --name=wireguard --restart=unless-stopped --network=host \
  --cap-add=NET_ADMIN --device /dev/net/tun \
  -e PUID=1000 -e PGID=1000 -e TZ=Asia/Shanghai \
  -e SERVERURL=your.ddns.domain -e SERVERPORT=51820 \
  -e PEERS=phone,laptop -e INTERNAL_SUBNET=10.9.0.0 \
  -e ALLOWEDIPS=10.31.0.0/16,10.9.0.0/24 -e PEERDNS=<路由器LAN_IP> \
  -e WG_QUICK_USERSPACE_IMPLEMENTATION=wireguard-go \
  -v /mnt/usb-xxx/wireguard/config:/config \
  rc06-wireguard:1.0

# 4. 宿主机放行 (按你的 LAN 网段调整)
iptables -t nat -I POSTROUTING -s 10.9.0.0/24 -j MASQUERADE
iptables -I FORWARD -s 10.9.0.0/24 -j ACCEPT
iptables -I FORWARD -d 10.9.0.0/24 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 5. 路由器管理页添加端口转发: UDP 51820 → 路由器自身 51820
# 6. 客户端配置在 <USB>/config/peer_*/ 下, 扫码/导入即用
```

> 注: `--network=host` 模式下**不要**加 `--sysctl net.ipv4.conf.all.src_valid_mark=1`, Docker 会拒绝启动。

## 客户端

- 配置由容器自动生成 (`$INTERNAL_SUBNET` 内编址), 二维码 PNG 在各 peer 目录
- 移动网络下若连不上而服务端握手正常, 优先怀疑运营商 DNS 缓存了旧 DDNS 记录 —— 可临时把 Endpoint 写成当前公网 IP 验证
- 家内网同网段下测试公网隧道会因 NAT 回环失败, 请用手机流量测

## 从源码构建 wireguard-go

```sh
./build-wireguard-go.sh   # 需 Go >= 1.23; 从 git.zx2c4.com 拉源码 + 应用补丁 + 交叉编译
```

## 已知限制

- `wg0 rx_dropped` 会随时间缓慢增长: 这是无 vnet 模式下 wireguard-go 的 tun 探测空写被计数, 无害
- 用户态实现吞吐受 CPU 限制 (IPQ807x 实测百兆级), 内网千兆不在预期内
- 小米固件 `/etc` 位于 ramfs: SSH 与防火墙规则需自备持久化 (cron + /data), 不属于本项目范围

## License

wireguard-go 为 GPLv2, 本项目的补丁与衍生分发遵循同等条款, 见 [LICENSE](LICENSE)。
