# Rockchip GStreamer Multimedia for Ubuntu

在 Ubuntu 24.04 (ARM64) 上构建带 Rockchip 硬件加速补丁的 GStreamer .deb 包。

适用于 RK3588 / RK3576 / RK356x 等 Rockchip SoC 平台。

## 功能特性

- **MPP 硬件编解码** — 通过 gstreamer1.0-rockchip 插件调用 Rockchip MPP（Media Process Platform）
- **RGA 2D 加速** — videoconvert / video-flip 等 element 使用 RGA 硬件加速
- **KMS/Wayland 增强** — kmssink / waylandsink 支持 HDR、AFBC、NV12_10LE40 等扩展格式
- **DMABuf 零拷贝** — 全链路 DMABuf 传递，减少内存拷贝

## 构建产物

| 包名 | 说明 |
|------|------|
| `rockchip-mpp` | Rockchip Media Process Platform 运行时库 |
| `rockchip-mpp-dev` | MPP 开发文件 |
| `librga2` | Rockchip RGA 2D 加速库 |
| `librga-dev` | RGA 开发文件 |
| `libgstreamer1.0-0` | GStreamer 1.24.2 核心库（含 Rockchip 补丁） |
| `gstreamer1.0-plugins-base` | GStreamer base 插件（RGA 加速） |
| `gstreamer1.0-plugins-good` | GStreamer good 插件（V4L2/RGA 增强） |
| `gstreamer1.0-plugins-bad` | GStreamer bad 插件（KMS/Wayland 增强） |
| `gstreamer1.0-rockchip` | Rockchip MPP 硬件编解码插件 |

## 前置条件

- x86_64 主机（通过 QEMU 用户模式模拟 ARM64 构建）
- Docker
- QEMU binfmt_misc 支持

```bash
# Ubuntu / Debian
sudo apt install docker.io qemu-user-static binfmt-support
```

## 快速开始

```bash
# 完整构建（所有 8 个阶段）
./build-rockchip-gstreamer.sh build

# 构建完成后，.deb 包在 build-gst-rockchip/debs/ 目录下
ls build-gst-rockchip/debs/*.deb
```

## 构建命令

```bash
# 完整构建
./build-rockchip-gstreamer.sh build

# 单阶段构建
./build-rockchip-gstreamer.sh build --only <phase>

# 从指定阶段开始构建
./build-rockchip-gstreamer.sh build --from <phase>

# 查看构建状态
./build-rockchip-gstreamer.sh status

# 清理构建产物
./build-rockchip-gstreamer.sh clean

# 清理所有（包括 Docker 容器和镜像）
./build-rockchip-gstreamer.sh clean --all
```

**构建阶段：** `setup` → `mpp` → `librga` → `gstreamer` → `plugins-base` → `plugins-good` → `plugins-bad` → `gst-rockchip`

## 安装

将生成的 .deb 包复制到目标 ARM64 设备上：

```bash
sudo dpkg -i build-gst-rockchip/debs/*.deb
sudo apt-get install -f  # 安装缺失的依赖
```

## 项目结构

```
├── build-rockchip-gstreamer.sh   # 主构建脚本
├── Dockerfile.gst-builder        # ARM64 构建容器
├── patch/                        # Rockchip GStreamer 补丁
│   ├── gstreamer/                #   核心库 (4 patches)
│   ├── gst-plugins-base/         #   base 插件 (22 patches)
│   ├── gst-plugins-good/         #   good 插件 (12 patches)
│   └── gst-plugins-bad/          #   bad 插件 (45 patches)
└── build-gst-rockchip/           # 构建产物 (gitignored)
```

## 补丁来源

补丁基于 [JeffyCN/meta-rockchip](https://github.com/aspect-building/meta-rockchip)（Rockchip Yocto BSP）的 GStreamer patches，适配到 upstream GStreamer 1.24.2。

主要修改：
- KMS/Wayland sink 增强（HDR、全屏、图层、AFBC、DMABuf）
- V4L2 源增强（设备过滤、分辨率限制、缓冲区管理）
- GL/EGL DMABuf 直接导入支持
- RGA 2D 加速集成
- MPP 硬件编解码集成

## 版本信息

| 组件 | 版本 |
|------|------|
| GStreamer | 1.24.2 |
| Ubuntu | 24.04 (Noble) |
| MPP | mpp-dev-2024_06_27 |
| RGA | linux-rga-multi |

## License

GStreamer 遵循 LGPL 许可证。Rockchip MPP 和 RGA 库遵循各自的许可证。补丁文件沿用上游许可证。
