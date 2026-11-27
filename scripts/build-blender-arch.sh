#!/usr/bin/env bash
# 在 Arch Linux ARM 容器内运行（root，工作目录 /work，即仓库根目录挂载点）。
# 用法：bash scripts/build-blender-arch.sh <tag> <standard|lite>
#   tag 例如 v5.3.0；standard 用 `make release ninja`，lite 用 `make lite ninja`。
#
# 流程就是 Blender 官方 Linux 源码构建流程，不走 PKGBUILD：
#   1. pacman 装构建工具 + 图形/音频系统库
#   2. git clone Blender 源码（github 镜像，tag 定点）
#   3. make update：拉子模块 + 官方预编译 lib-linux_arm64（arm64 专用，2026-10 起由 make update 自动使用）
#   4. make release ninja：CMake 配置 + 编译 + 安装到 build 目录（便携布局）
#   5. package_archive 打包，产物放 /work/out/
#
# 关键取舍（都写在 BUILD_CMAKE_ARGS 里）：
# - Cycles 的 CUDA / OptiX / HIP / oneAPI 设备支持全部关掉：通用 ARM64 机器没有
#   这些 GPU 工具链，开着只会让 CMake 报错或白白编译 GPU 内核；Cycles CPU 渲染不受影响。
# - 不关 Embree / OIDN / OpenVDB / USD 等：它们在 lib-linux_arm64 预编译库里有 arm64 版。
set -euo pipefail

TAG="${1:?用法：$0 <tag 如 v5.3.0> <standard|lite>}"
TARGET="${2:-standard}"
VER="${TAG#v}"

echo "==> 构建 Blender $TAG（目标 $TARGET）"
uname -m
test "$(uname -m)" = "aarch64" || { echo "::error::必须在 aarch64 容器里构建，当前是 $(uname -m)"; exit 1; }
nproc
free -h
df -h
date

echo "==> pacman 初始化并滚动更新"
pacman-key --init
pacman-key --populate archlinuxarm
pacman -Sy --noconfirm archlinuxarm-keyring
pacman -Syu --noconfirm

echo "==> 安装核心构建工具"
pacman -S --noconfirm --needed base-devel cmake ninja git git-lfs subversion python zstd xz

echo "==> 安装图形/音频系统库（逐个装，缺失的跳过，不让单个包名拖垮整个构建）"
for pkg in libx11 libxxf86vm libxcursor libxi libxrandr libxinerama libegl mesa \
           wayland wayland-protocols libxkbcommon libdecor libepoxy \
           sdl2 jack2 libsndfile freetype2 fontconfig alsa-lib libpulse \
           vulkan-icd-loader vulkan-headers shaderc patchelf nasm; do
  pacman -S --noconfirm --needed "$pkg" || echo "::warning::跳过系统包 $pkg"
done

git lfs install || true

echo "==> 拉取 Blender 源码 $TAG"
rm -rf blender-git/blender
mkdir -p blender-git
git clone --depth 1 --branch "$TAG" https://github.com/blender/blender.git blender-git/blender
cd blender-git/blender
git log --oneline -1
git status --short --branch | head -n 5 || true

echo "==> make update：子模块 + 官方预编译 lib-linux_arm64"
# 默认不拉 tests（--use-tests 才是拉测试数据），lib 目录命中缓存时会做 svn update 增量更新。
make update

echo "==> 预编译库检查"
ls lib/linux_arm64/ | head -n 30
test -d lib/linux_arm64/python || { echo "::error::lib/linux_arm64/python 不存在，预编译库没拉下来"; exit 1; }
df -h

echo "==> 编译（这一步最久，2 核约数小时）"
export BUILD_CMAKE_ARGS="-DWITH_CYCLES_DEVICE_CUDA=OFF -DWITH_CYCLES_DEVICE_OPTIX=OFF -DWITH_CYCLES_DEVICE_HIP=OFF -DWITH_CYCLES_DEVICE_ONEAPI=OFF -DWITH_INSTALL_PORTABLE=ON"
if [ "$TARGET" = "lite" ]; then
  make lite ninja
  BUILD_DIR="../build_linux_lite"
else
  make release ninja
  BUILD_DIR="../build_linux_release"
fi

echo "==> 编译完成，检查产物"
ls -lh "$BUILD_DIR/bin/blender"
"$BUILD_DIR/bin/blender" --version
df -h

echo "==> 打包"
mkdir -p /work/out
# 优先用 Blender 自带的 package_archive（官方打包方式，产物在 build 目录的 release/ 下）
if cmake --build "$BUILD_DIR" --target package_archive; then
  ls -lh "$BUILD_DIR/release/"
  cp "$BUILD_DIR"/release/blender-*.tar.* /work/out/
else
  echo "::warning::package_archive 失败，改用手动打包 build 目录的 bin/ 便携布局"
  tar --zstd -cf "/work/out/blender-${VER}-linux-aarch64-arch.tar.zst" -C "$BUILD_DIR/bin" .
fi

echo "==> 最终产物"
ls -lh /work/out/
for f in /work/out/*; do
  tar --list --zstd --file "$f" 2>/dev/null | head -n 15 \
    || tar --list --xz --file "$f" 2>/dev/null | head -n 15 \
    || tar --list --gzip --file "$f" 2>/dev/null | head -n 15 || true
done
date
echo "==> 构建成功"
