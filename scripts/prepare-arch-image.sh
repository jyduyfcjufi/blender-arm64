#!/usr/bin/env bash
# 在 GitHub Actions 的 ubuntu-24.04-arm runner（宿主机）上运行。
# 目标：用 Arch Linux ARM 官方 rootfs tarball 做出一个本地 Docker 镜像 arch-arm64:local。
#
# 为什么不用 Docker Hub 上的现成 Arch ARM 镜像：
# 官方 archlinux 镜像只有 amd64；第三方 Arch ARM 镜像（stephank、samip537 等）
# 最后更新是 2017 / 2020 年，早已过期，pacman 仓库和 keyring 都不可用。
# 官方 tarball 是唯一可信的底包来源。
set -euo pipefail

TARBALL="/tmp/ArchLinuxARM-aarch64-latest.tar.gz"

URLS=(
  "http://mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
  "https://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
  "https://de.mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
  "https://uk.mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
  "https://ca.us.mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
)

rm -f "$TARBALL"
downloaded=""
for url in "${URLS[@]}"; do
  echo "==> 尝试下载 $url"
  if curl -L --retry 3 --retry-delay 5 --connect-timeout 30 --max-time 600 -o "$TARBALL" "$url"; then
    # 校验：文件要大于 50MB，且 gzip 完整
    size=$(stat -c%s "$TARBALL" 2>/dev/null || echo 0)
    if [ "$size" -gt 50000000 ] && gzip -t "$TARBALL" 2>/dev/null; then
      echo "==> 下载成功：$url（$size 字节）"
      downloaded=1
      break
    fi
    echo "::warning::从 $url 下载的文件异常（大小 $size），换下一个源"
    rm -f "$TARBALL"
  else
    echo "::warning::从 $url 下载失败，换下一个源"
    rm -f "$TARBALL"
  fi
done

if [ -z "$downloaded" ]; then
  echo "::error::所有 Arch Linux ARM 官方源都下载失败"
  exit 1
fi

echo "==> tarball 内容抽查"
# 注意：不要用 `tar -tzf file | head/grep -q` 的写法。本脚本有 pipefail，
# head/grep 提前退出会让 tar 写管道失败（tar: stdout: write error，exit 2），
# 上次构建就是这样在下载成功后白白失败的。先把清单写到文件再查。
tar -tzf "$TARBALL" > /tmp/alarm-file-list.txt
head -n 10 /tmp/alarm-file-list.txt
grep -q "etc/pacman.conf" /tmp/alarm-file-list.txt || { echo "::error::tarball 里没有 etc/pacman.conf，不是 Arch rootfs"; exit 1; }
rm -f /tmp/alarm-file-list.txt

echo "==> docker import 为 arch-arm64:local"
docker import "$TARBALL" arch-arm64:local

echo "==> 验证镜像"
docker run --rm arch-arm64:local uname -m
docker run --rm arch-arm64:local cat /etc/os-release
docker images arch-arm64:local
