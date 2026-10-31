# rc06-wireguard: linuxserver/wireguard + 高通魔改内核适配
#
# 适配点 (相对官方镜像):
#   1. /usr/bin/wireguard-go —— 去 IFF_VNET_HDR 的用户态实现
#      (厂商 tun 驱动静默丢弃带 virtio-net 头的写入, 数据面全死)
#   2. init-wireguard-module/run —— 跳过内核模块检测
#      (本环境内核无 wireguard 模块, 官方脚本会 sleep infinity 卡死启动)
#
# 密钥与 peer 配置不进镜像, 运行时挂载 /config。

FROM docker.m.daocloud.io/linuxserver/wireguard:latest

COPY prebuilt/wireguard-go-linux-arm64 /usr/bin/wireguard-go
COPY s6/init-wireguard-module-skip.sh /etc/s6-overlay/s6-rc.d/init-wireguard-module/run

RUN chmod 755 /usr/bin/wireguard-go /etc/s6-overlay/s6-rc.d/init-wireguard-module/run
