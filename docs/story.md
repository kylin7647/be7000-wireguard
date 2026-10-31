# 排障实录: 握手一切正常, 数据面却全军覆没

> 一份给后来者的完整排查记录。如果你也在高通 IPQ 魔改内核的路由器上用
> wireguard-go, 遇到 "wg show 双向流量都在涨, 但隧道里一个包都出不来",
> 这篇就是为你写的。

## 症状

- 手机/测试客户端握手成功, `wg show` 两端 transfer 都在涨
- 服务端 `ip -s link show wg0`: **RX 恒等于 0**, 且无任何错误日志
- 隧道内 ping/web 全部 100% 丢包

## 排除过程 (每一步都有实证)

1. **DDNS/DNS**: 三大公共解析器交叉比对 TTL 与解析值, 排除旧记录
2. **端口转发/DNAT**: `iptables -t nat -S zone_wan_prerouting` 确认规则存在
3. **包到达**: 在 zone_wan_prerouting 挂 LOG 探针, 抓到手机握手包进入 WAN ✓
4. **容器内 IP 栈**: `/proc/net/snmp` 显示 InReceives 增长 = 加密包到达 socket ✓
5. **TUN 计数器**: `ip -s link show wg0` RX=0 —— **包死在 wireguard-go 内部**
6. **strace**: `-e trace=write,writev` 全程只有 0 字节探测写, 无任何数据写
7. **源码审计** (`tun/tun_linux.go` CreateTUN):
   ```go
   ifr.SetUint16(unix.IFF_TUN | unix.IFF_NO_PI | unix.IFF_VNET_HDR)
   ```
   新版 wireguard-go 无条件启用 vnet 头 + GSO/USO 卸载
   (`TUN_F_USO4/USO6` 更是内核 5.18+ 才有的 ioctl)
8. **驱动对照组实验**: 在同一容器里用 Python + ctypes 直接创建 TUN 并写入,
   **裸包 (NO_PI) 和 PI 帧格式都被内核正确接收** —— 排除驱动完全损坏,
   锁定 "vnet 头帧格式" 这一个变量

## 根因

高通 IPQ 平台的厂商内核 (NSS 硬件卸载魔改) 的 tun 驱动, 会**静默丢弃
携带 virtio-net 头的写入**: write() 返回成功, 包消失, 计数器不动。
控制面 (握手 = 纯 UDP socket 收发) 完全不经过 TUN, 所以一切"看起来正常"。

## 修复

```diff
-	ifr.SetUint16(unix.IFF_TUN | unix.IFF_NO_PI | unix.IFF_VNET_HDR)
+	ifr.SetUint16(unix.IFF_TUN | unix.IFF_NO_PI)
```

交叉编译后替换二进制, 数据面立通。

## 第二层坑: docker-proxy 丢握手响应

数据面修好后做本地回环测试, 发现 bridge 模式下握手反而不完成了:
tcpdump 在 br-docker 上抓到服务端响应包已上线 (4ms 内, 目标地址正确),
但客户端 netns 的 socket 永远收不到 —— userland docker-proxy 的 UDP
中继在此环境不可靠。`--network=host` 让 :51820 直接监听宿主机,
绕过整层代理, 顺带消灭了对 docker-proxy 的全部依赖。

## 附注

- 修掉 vnet 后, wireguard-go 的 tun 探测空写 (0 字节, 期待 EINVAL)
  会被内核计入 rx_dropped, 导致 wg0 的 dropped 缓慢增长 —— 无害, 别被吓到
- wireguard-go 的日志级别环境变量是 `LOG_LEVEL` 不是 `WG_LOG_LEVEL`;
  且 daemonize 的实例日志会随父进程 stdout 关闭而丢失
