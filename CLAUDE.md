# Rockchip GStreamer Multimedia for Ubuntu

## 项目概述
为 ARM64 (Rockchip RK3588 等) 构建带硬件加速补丁的 GStreamer .deb 包。

## 项目结构
- `build-rockchip-gstreamer.sh` - 主构建脚本，使用 Docker ARM64 (QEMU) 交叉编译
- `Dockerfile.gst-builder` - ARM64 构建容器定义 (Ubuntu 24.04)
- `99-rockchip-multimedia.rules` - udev 规则，为 MPP/VPU/RGA/DMA Heap 设备设置 video 组权限
- `patch/` - Rockchip GStreamer patches，按组件分目录：
  - `gstreamer/` - 核心库 (4 patches)
  - `gst-plugins-base/` - base 插件 (22 patches)
  - `gst-plugins-good/` - good 插件 (12 patches)
  - `gst-plugins-bad/` - bad 插件 (45 patches)
- `build-gst-rockchip/` - 构建产物目录 (gitignored)

## 构建命令
- `./build-rockchip-gstreamer.sh build` - 完整构建 (8 阶段)
- `./build-rockchip-gstreamer.sh build --only <phase>` - 单阶段构建 (setup/mpp/librga/gstreamer/plugins-base/plugins-good/plugins-bad/gst-rockchip)
- `./build-rockchip-gstreamer.sh build --from <phase>` - 从指定阶段开始
- `./build-rockchip-gstreamer.sh status` - 查看构建状态
- `./build-rockchip-gstreamer.sh clean` / `clean --all` - 清理

## 构建脚本关键行为
- 源码仅在目录不存在时解压和 patch (`if [ ! -d "${src}" ]`)
- 修改 patch 后需删除旧的源码目录才能生效
- 构建在 Docker ARM64 容器内通过 QEMU 用户模式模拟执行
- 每个阶段构建的 .deb 会自动安装到容器中供后续阶段使用

## Patch 适配注意事项
- Patches 来源于 Rockchip Yocto BSP (JeffyCN)，适配到 upstream GStreamer 1.24.2
- 适配流程：解压源码 → git init → 逐个 git am，FAIL 的用 patch --fuzz=3 或手动修复 → git format-patch
- Patch 顺序影响应用结果：独立测试 FAIL 的 patch 可能在顺序应用时因上下文变化而成功
- 已集成到上游的 patch（git am 报 "Reversed"）应丢弃
- fuzz 应用的 patch 需仔细检查：代码可能被放到错误位置（如注释块内、错误的函数中）

## 版本
- GStreamer: 1.24.2
- Ubuntu: 24.04 (Noble)
- MPP: mpp-dev-2024_06_27
- RGA: linux-rga-multi

## 语言
与用户使用中文沟通。
