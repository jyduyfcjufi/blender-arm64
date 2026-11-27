# Blender for Linux ARM64（Arch 源码构建）

用 GitHub Actions 直接从源码构建最新 Blender，给 **Arch Linux ARM aarch64** 用。

## 为什么需要这个仓库

- Arch Linux ARM 官方仓库里的 Blender 停在 **3.6.5**（2023 年），而 Blender 最新稳定版是 **5.3.0**（2026-11-10）。
- Blender 官方不提供 Linux ARM64 二进制，但从 2026-10 起官方提供了预编译 `lib-linux_arm64`，`make update` 会自动使用，ARM64 源码构建和 x86 基本一样了。

## 构建方式（直接源码构建，不走 PKGBUILD）

1. GitHub Actions 跑在 `ubuntu-24.04-arm` 原生 ARM64 runner 上。
2. `scripts/prepare-arch-image.sh` 从 Arch Linux ARM 官方源下载 `ArchLinuxARM-aarch64-latest.tar.gz`，`docker import` 成本地镜像 `arch-arm64:local`。
   Docker Hub 上没有可用的 Arch ARM 镜像：官方 `archlinux` 只有 amd64，第三方镜像最后更新是 2017 / 2020 年，已过期。
3. `scripts/build-blender-arch.sh` 在容器里跑 Blender 官方流程：
   `git clone` 源码 → `make update`（子模块 + 预编译 `lib-linux_arm64`）→ `make release ninja` → `package_archive` 打包。
4. 产物是解压即用的便携包，上传为 Artifact（保留 90 天），并同时发一个 GitHub Release。

## 关键取舍

- **版本**：默认 `v5.3.0`，触发时可以改成任意 `vX.Y.Z` tag。
- **Cycles GPU 二进制全部禁用**：CUDA / OptiX / HIP / oneAPI。通用 ARM64 机器没有这些 GPU 工具链，开着只会报错或白白编译 GPU 内核；Cycles **CPU 渲染不受影响**。
- Embree / OpenImageDenoise / OpenVDB / USD 等保持开启，它们在 `lib-linux_arm64` 里有 arm64 版。
- CPU 要求：`armv8.2-a+dotprod+fp16+lse`，树莓派 5、骁龙 845 及更新、大多数 ARM64 机器都满足。

## 怎么触发

Actions → **Build Blender Linux ARM64** → Run workflow：

| 输入 | 默认 | 说明 |
| --- | --- | --- |
| `blender_tag` | `v5.3.0` | 要构建的 Blender tag |
| `build_target` | `standard` | `standard` = 官方 release 全功能；`lite` = 精简更快 |
| `create_release` | `true` | 成功后发 Release，tag 为 `<版本>-arch-arm64` |

只在手动触发时构建，push 代码不会触发，避免误触几小时的构建。

## 在 Arch ARM 机器上安装

```bash
tar -xf blender-5.3.0-linux-aarch64*.tar.*
cd blender-5.3.0-linux-aarch64
./blender --version
./blender
```

## 已知限制

- **这个仓库目前是私有仓库**：GitHub 的 ARM runner 在私有仓库只有 **2 核 / 8G**，还要按分钟计费，完整构建预计数小时，链接阶段可能吃满内存（工作流里已加 8G swap 兜底）。
  改成**公开仓库**后是 **4 核 / 16G、免费**，构建会快很多。改不改由仓库所有者决定。
- 单次构建超时上限 6 小时；`lib-linux_arm64` 预编译库有缓存，重复构建同一版本会快一些。
- 旧工作流（2026-02，Ubuntu + apt + Python 3.11 + deadsnakes PPA）已废弃：deadsnakes PPA 没有 arm64 包，那 4 次构建全失败了。本次重写为 Arch 容器 + 直接源码构建。
