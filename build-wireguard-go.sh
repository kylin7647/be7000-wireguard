#!/bin/sh
# 从上游源码构建"去 vnet 头"版 wireguard-go (linux/arm64)
# 依赖: Go >= 1.23, curl, tar, xz, patch
# 产物: prebuilt/wireguard-go-linux-arm64
set -e

VER=0.0.20250522
OUT="$(dirname "$0")/prebuilt/wireguard-go-linux-arm64"
WORK="$(mktemp -d)"

echo "==> 拉取上游源码 wireguard-go ${VER}"
curl -sL --max-time 120 \
  "https://git.zx2c4.com/wireguard-go/snapshot/wireguard-go-${VER}.tar.xz" \
  -o "$WORK/src.tar.xz"

echo "==> 解压并应用补丁"
tar -xJf "$WORK/src.tar.xz" -C "$WORK"
cd "$WORK/wireguard-go-${VER}"
patch -p1 < "$(dirname "$0")/patches/0001-remove-iff-vnet-hdr.patch"

echo "==> 交叉编译 CGO_ENABLED=0 GOOS=linux GOARCH=arm64"
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
  go build -trimpath -ldflags="-s -w" -o "$OUT" .

echo "==> 完成: $OUT"
file "$OUT" 2>/dev/null || ls -la "$OUT"
