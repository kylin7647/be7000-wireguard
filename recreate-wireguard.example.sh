#!/bin/sh
# 一键重建 WireGuard 容器 (小米路由器 RC06/BE7000 实测版)
# 参数化版本 —— 按你的环境修改下方变量后使用
# 前提: root SSH, Docker 插件启用, USB 挂载, 本目录已在 USB 上
set -e

# ========= 按需修改 =========
USB=/mnt/usb-151e6d47                 # USB 挂载点
LAN_SUBNET=10.31.0.0/16               # 家里 LAN 网段 (给客户端 AllowedIPs)
WG_SUBNET=10.9.0.0                    # 隧道网段
SERVERURL=your.ddns.example           # 你的 DDNS 域名
PEERS=phone,laptop                    # 初始客户端名
# ============================

D=$USB/mi_docker/docker-binaries/docker
B=$USB/wireguard

# --- 1) 放宽小米 opa-docker-authz 策略 (仅允许 NET_ADMIN; tmpfs 重启即还原) ---
mkdir -p /tmp/run/docker/opa
cat > /tmp/run/docker/opa/authz.rego << 'REGO'
package docker.authz
default allow = false
allow { not deny }
deny { c = input.Body.HostConfig.CapAdd[_]; c != "NET_ADMIN" }
deny { input.Body.HostConfig.Privileged == true }
deny { m = input.Body.HostConfig.Binds[_]; not regex.match("^(/mnt/usb-[^:]+|/var/run/docker.sock):[^:]+$", m) }
deny { m = input.BindMounts[_].Resolved; not regex.match("^(/mnt/usb-[^:]+|/(var|tmp)/run/docker.sock)$", m) }
REGO
kill $(ps w | grep "[o]pa-docker-authz" | awk '{print $1}') 2>/dev/null
sleep 1
($D/../opa-docker-authz -policy-file /tmp/run/docker/opa/authz.rego < /dev/null > /tmp/opa.log 2>&1 &)
sleep 2

# --- 2) 镜像: 本仓库构建 (或 docker load 离线包) ---
(cd $B/image-build 2>/dev/null && $D build -t rc06-wireguard:1.0 .) || \
  $D load -i $B/rc06-wireguard-image.tar || \
  { echo "缺少镜像与构建上下文"; exit 1; }

# --- 3) 启动 (host 网络) ---
$D rm -f wireguard >/dev/null 2>&1
$D run -d --name=wireguard --restart=unless-stopped --network=host \
  --cap-add=NET_ADMIN --device /dev/net/tun \
  -e PUID=1000 -e PGID=1000 -e TZ=Asia/Shanghai \
  -e SERVERURL=$SERVERURL -e SERVERPORT=51820 -e PEERS=$PEERS \
  -e INTERNAL_SUBNET=$WG_SUBNET -e ALLOWEDIPS=$LAN_SUBNET,$WG_SUBNET/24 \
  -e PEERDNS=<路由器LAN_IP> -e WG_QUICK_USERSPACE_IMPLEMENTATION=wireguard-go \
  -v $B/config:/config \
  rc06-wireguard:1.0

# --- 4) 宿主机 NAT/FORWARD ---
iptables -t nat -C POSTROUTING -s $WG_SUBNET/24 -j MASQUERADE 2>/dev/null || \
  iptables -t nat -I POSTROUTING -s $WG_SUBNET/24 -j MASQUERADE
iptables -C FORWARD -s $WG_SUBNET/24 -j ACCEPT 2>/dev/null || \
  iptables -I FORWARD -s $WG_SUBNET/24 -j ACCEPT
iptables -C FORWARD -d $WG_SUBNET/24 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
  iptables -I FORWARD -d $WG_SUBNET/24 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

echo "=== 完成。验证: $D exec wireguard wg show wg0 ==="
echo "建议: 用 cron 每分钟执行本文件第 4 段 (iptables 自愈), 固件 /etc 重启即清"
