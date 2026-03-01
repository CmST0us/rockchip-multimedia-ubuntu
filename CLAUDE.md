# Rockchip GStreamer Multimedia for Ubuntu

## 项目概述
为 ARM64 (Rockchip RK3588 等) 构建带硬件加速补丁的 GStreamer .deb 包。

## 项目结构
- `build-rockchip-gstreamer.sh` - 主构建脚本，使用 Docker ARM64 (QEMU) 交叉编译
- `patch/` - Rockchip GStreamer patches，按组件分目录 (gstreamer, gst-plugins-base, gst-plugins-good, gst-plugins-bad)
- `Dockerfile.gst-builder` - ARM64 构建容器定义
- `build-gst-rockchip/` - 构建产物目录 (gitignored)

## 构建命令
- `./build-rockchip-gstreamer.sh build` - 完整构建
- `./build-rockchip-gstreamer.sh build --only <phase>` - 单阶段构建 (setup/mpp/librga/gstreamer/plugins-base/plugins-good/plugins-bad/gst-rockchip)
- `./build-rockchip-gstreamer.sh build --from <phase>` - 从指定阶段开始
- `./build-rockchip-gstreamer.sh clean` / `clean --all` - 清理

## Patch 适配注意事项
- Patches 来源于 Rockchip Yocto BSP (JeffyCN)，适配到 upstream GStreamer 版本
- 适配流程：解压源码 → git init → 逐个 git am，FAIL 的用 patch --fuzz=3 或手动修复 → git format-patch
- Patch 顺序影响应用结果：独立测试 FAIL 的 patch 可能在顺序应用时因上下文变化而成功
- 已集成到上游的 patch（git am 报 "Reversed"）应丢弃

## 语言
与用户使用中文沟通。
