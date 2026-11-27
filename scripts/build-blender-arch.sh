#!/usr/bin/env bash
# 在 Arch Linux ARM 容器内运行（root，工作目录 /work，即仓库根目录挂载点）。
# 用法：bash scripts/build-blender-arch.sh <tag> <standard|lite>
#   tag 例如 v5.3.0；standard 用 `make release ninja`，lite 用 `make lite ninja`。
#
# 流程就是 Blender 官方 Linux 源码构建流程，不走 PKGBUILD：
#   1. pacman 装构建工具 + 图形/音频系统库
#   2. git clone Blender 源码（官方源 projects.blender.org，--depth 1 浅克隆，tag 定点）
#   3. make update：子模块（浅克隆） + 官方预编译 lib-linux_arm64（arm64 专用，2026-10 起由 make update 自动使用）
#   4. 用 CMake 3.31.8 官方二进制（盖掉 Arch 自带的 cmake 4.5.1，见下文注释），
#      make release ninja：CMake 配置 + 编译 + 安装到 build 目录（便携布局）
#   5. package_archive 打包，产物放 /work/out/
#
# 关键取舍（都写在 BUILD_CMAKE_ARGS 里）：
# - Cycles 的 CUDA / OptiX / HIP / oneAPI 设备支持全部关掉：通用 ARM64 机器没有
#   这些 GPU 工具链，开着只会让 CMake 报错或白白编译 GPU 内核；Cycles CPU 渲染不受影响。
# - 光关 DEVICE_* 还不够：WITH_CYCLES_*_BINARIES 默认 ON，ninja 仍会编译 GPU 内核，
#   没有 nvcc/hipcc 会直接失败，所以 *_BINARIES 和 HIPRT 也要显式关掉。
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
# 注意：pacman 7 默认用 Landlock 沙箱下载/安装，但 GitHub hosted runner 的
# Docker 里没有应用 Landlock 规则集的权限，会报
# "restricting filesystem access failed ... Operation not permitted" /
# "switching to sandbox user 'alpm' failed"，导致 pacman -Syu 直接失败。
# 容器内一次性构建用 --disable-sandbox 是通行做法。
pacman-key --init
pacman-key --populate archlinuxarm
pacman -Sy --noconfirm --disable-sandbox archlinuxarm-keyring
pacman -Syu --noconfirm --disable-sandbox

echo "==> 安装核心构建工具"
pacman -S --noconfirm --disable-sandbox --needed base-devel cmake ninja git git-lfs subversion python zstd xz curl

echo "==> 安装图形/音频系统库（逐个装，缺失的跳过，不让单个包名拖垮整个构建）"
for pkg in libx11 libxxf86vm libxcursor libxi libxrandr libxinerama libegl mesa \
           wayland wayland-protocols libxkbcommon libdecor libepoxy \
           sdl2 jack2 libsndfile freetype2 fontconfig alsa-lib libpulse \
           vulkan-icd-loader vulkan-headers shaderc patchelf nasm; do
  pacman -S --noconfirm --disable-sandbox --needed "$pkg" || echo "::warning::跳过系统包 $pkg"
done

git lfs install || true

echo "==> 拉取 Blender 源码 $TAG"
rm -rf blender-git/blender
mkdir -p blender-git
# 注意：必须从官方源克隆。GitHub 镜像（github.com/blender/blender）的 LFS
# 不完整，run 46063180349 就是在 checkout 时下载
# assets/brushes/essentials_brushes-curve_sculpt.blend 报 404
#（Object does not exist on the server），导致 clone 失败 exit 128。
# 官方源 projects.blender.org 是正本，LFS 对象都在那里。
# 万一官方源连不上，再退回 GitHub 镜像并跳过 LFS（资产可能不完整）。
if ! git clone --depth 1 --branch "$TAG" https://projects.blender.org/blender/blender.git blender-git/blender; then
  echo "::warning::官方源克隆失败，改用 GitHub 镜像并跳过 LFS 下载"
  GIT_LFS_SKIP_SMUDGE=1 git clone --depth 1 --branch "$TAG" https://github.com/blender/blender.git blender-git/blender
fi
cd blender-git/blender
git log --oneline -1
git status --short --branch | head -n 5 || true

echo "==> 子模块浅克隆配置（只拉一层历史）"
# make update 内部跑 `git submodule update --init`，不带 --depth，
# 预编译库 lib/linux_arm64 等子模块会全量克隆历史，又大又慢。
# 把 shallow=true 写进 .gitmodules 和本地配置，submodule update 就按 --depth 1 克隆。
git config -f .gitmodules --get-regexp '^submodule\..*\.path$' | while read -r key _path; do
  name="${key#submodule.}"
  name="${name%.path}"
  git config -f .gitmodules "submodule.${name}.shallow" true
  git config "submodule.${name}.shallow" true
done
git config -f .gitmodules --get-regexp '^submodule\..*\.shallow$' || echo "::warning::浅克隆配置未生效（继续全量克隆子模块）"

echo "==> make update：子模块 + 官方预编译 lib-linux_arm64"
# 默认不拉 tests（--use-tests 才是拉测试数据），lib 目录命中缓存时会做 svn update 增量更新。
make update

echo "==> 预编译库检查"
ls lib/linux_arm64/ | head -n 30
test -d lib/linux_arm64/python || { echo "::error::lib/linux_arm64/python 不存在，预编译库没拉下来"; exit 1; }
df -h

echo "==> 安装 CMake 3.31.8（官方 aarch64 二进制）"
# Arch 自带 cmake 4.5.1，而 Blender 5.3.0 的 source/creator/CMakeLists.txt
# 用了 install(CODE ... DEPENDS blender)，CMake 4 不认 DEPENDS 参数，
# configure 直接报错（run 46063726480 就是这么死的）。
# Blender 只要求 CMake >= 3.21，用官方 3.31.8 二进制并校验 SHA-256，
# 放 PATH 最前面盖掉系统 cmake。
CMAKE_TGZ="cmake-3.31.8-linux-aarch64.tar.gz"
CMAKE_SHA256="609735983e3bdf24b6ab379d918458d64196fe72b98226f62dd5e9fe7b2997cc"
curl -fL -o "/tmp/${CMAKE_TGZ}" "https://github.com/Kitware/CMake/releases/download/v3.31.8/${CMAKE_TGZ}"
echo "${CMAKE_SHA256}  /tmp/${CMAKE_TGZ}" | sha256sum -c -
mkdir -p /opt/cmake-3.31
tar -xzf "/tmp/${CMAKE_TGZ}" -C /opt/cmake-3.31 --strip-components=1
export PATH="/opt/cmake-3.31/bin:$PATH"
cmake --version | head -n 1

echo "==> 编译（这一步最久，2 核约数小时）"
# Cycles 的 CUDA / OptiX / HIP / oneAPI 设备支持全部关掉：通用 ARM64 机器没有
# 这些 GPU 工具链，开着只会让 CMake 报错或白白编译 GPU 内核；Cycles CPU 渲染不受影响。
# 注意：光关 DEVICE_* 还不够——WITH_CYCLES_*_BINARIES 默认是 ON，
# ninja 仍会去编译 CUDA/HIP/oneAPI 内核（.ptx），而机器上没有 nvcc/hipcc，
# 命令行为空直接报 command not found（run 46065227025 就是死在
# kernel_compute_75.ptx 上）。所以 *_BINARIES 也要显式关掉；HIPRT 同理。
export BUILD_CMAKE_ARGS="-DWITH_CYCLES_DEVICE_CUDA=OFF -DWITH_CYCLES_DEVICE_OPTIX=OFF -DWITH_CYCLES_DEVICE_HIP=OFF -DWITH_CYCLES_DEVICE_ONEAPI=OFF -DWITH_CYCLES_DEVICE_HIPRT=OFF -DWITH_CYCLES_CUDA_BINARIES=OFF -DWITH_CYCLES_HIP_BINARIES=OFF -DWITH_CYCLES_ONEAPI_BINARIES=OFF -DWITH_INSTALL_PORTABLE=ON"
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
  # 同 prepare 脚本：清单先写文件再 head，避免 tar | head 的 SIGPIPE 误判。
  _list=$(mktemp)
  if tar --list --zstd --file "$f" > "$_list" 2>/dev/null \
    || tar --list --xz --file "$f" > "$_list" 2>/dev/null \
    || tar --list --gzip --file "$f" > "$_list" 2>/dev/null; then
    head -n 15 "$_list"
  fi
  rm -f "$_list"
done
date
echo "==> 构建成功"
