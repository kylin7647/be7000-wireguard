#!/usr/bin/with-contenv bash
# 替换 linuxserver/wireguard 的 init-wireguard-module/run:
# 官方脚本在检测不到内核 wireguard 模块时会 echo 提示并 sleep infinity,
# 导致 s6 后续服务 (配置生成/隧道拉起) 永远不执行。
# 本环境通过 bind mount / 镜像内置的 wireguard-go 走用户态回退,
# 由 svc-wireguard 的 wg-quick + WG_QUICK_USERSPACE_IMPLEMENTATION 完成。
echo "**** Kernel module not present - using userspace wireguard-go (patched) ****"
