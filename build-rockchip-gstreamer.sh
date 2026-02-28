#!/bin/bash
set -euo pipefail

# ============================================================
# Rockchip GStreamer .deb Build Script
# Builds ARM64 .deb packages for Rockchip multimedia stack
# using QEMU user-mode emulation in ARM64 chroot
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/build-gst-rockchip"
CHROOT_DIR="${WORK_DIR}/chroot"
SOURCES_DIR="${WORK_DIR}/sources"
BUILD_DIR="${WORK_DIR}/build"
DEBS_DIR="${WORK_DIR}/debs"
PACKAGES_DIR="${SCRIPT_DIR}/yocto-rockchip/packages"
PATCHES_BASE="${SCRIPT_DIR}/yocto-rockchip/meta-rockchip/recipes-multimedia/gstreamer"

# Versions
GST_VERSION="1.22.12"
GST_PATCH_VERSION="1.22.9"

# Source repos
MIRRORS_GIT="https://github.com/JeffyCN/mirrors.git"
MPP_BRANCH="mpp-dev-2024_06_27"
MPP_SRCREV="b29e4b798d28a5d0709bff87479d17f247645bc8"
LIBRGA_BRANCH="linux-rga-multi"
LIBRGA_SRCREV="c6105b06ade0e5dc7f16924c7f0f5e9dcdb198bc"
GST_ROCKCHIP_BRANCH="gstreamer-rockchip"
GST_ROCKCHIP_SRCREV="c37e7cf10283521c262f9e71fd9be0422a457989"

# Phase name to number mapping
declare -A PHASE_MAP=(
    [setup]=0 [mpp]=1 [librga]=2 [gstreamer]=3
    [plugins-base]=4 [plugins-good]=5 [plugins-bad]=6 [gst-rockchip]=7
)
PHASE_NAMES=(setup mpp librga gstreamer plugins-base plugins-good plugins-bad gst-rockchip)

# ============================================================
# Helper functions
# ============================================================

log() { echo "==> $*"; }
log_phase() { echo ""; echo "========================================"; echo "  Phase $1: $2"; echo "========================================"; }
err() { echo "ERROR: $*" >&2; exit 1; }

chroot_exec() {
    sudo chroot "${CHROOT_DIR}" /bin/bash -c "$*"
}

chroot_mount() {
    log "Mounting chroot filesystems..."
    sudo mount --bind /proc "${CHROOT_DIR}/proc" 2>/dev/null || true
    sudo mount --bind /sys "${CHROOT_DIR}/sys" 2>/dev/null || true
    sudo mount --bind /dev "${CHROOT_DIR}/dev" 2>/dev/null || true
    sudo mount --bind /dev/pts "${CHROOT_DIR}/dev/pts" 2>/dev/null || true
}

chroot_umount() {
    log "Unmounting chroot filesystems..."
    sudo umount "${CHROOT_DIR}/dev/pts" 2>/dev/null || true
    sudo umount "${CHROOT_DIR}/dev" 2>/dev/null || true
    sudo umount "${CHROOT_DIR}/sys" 2>/dev/null || true
    sudo umount "${CHROOT_DIR}/proc" 2>/dev/null || true
}

cleanup() {
    chroot_umount
}
trap cleanup EXIT

# Apply patches from meta-rockchip to a source directory
apply_patches() {
    local src_dir="$1"
    local patch_dir="$2"

    if [ ! -d "${patch_dir}" ]; then
        err "Patch directory not found: ${patch_dir}"
    fi

    local patches=($(ls "${patch_dir}"/*.patch 2>/dev/null | sort))
    if [ ${#patches[@]} -eq 0 ]; then
        log "No patches to apply from ${patch_dir}"
        return
    fi

    log "Applying ${#patches[@]} patches from $(basename "${patch_dir}")..."
    for patch in "${patches[@]}"; do
        log "  Applying: $(basename "${patch}")"
        (cd "${src_dir}" && git apply --check "${patch}" 2>/dev/null && git apply "${patch}") || \
        (cd "${src_dir}" && patch -p1 < "${patch}") || \
        err "Failed to apply patch: $(basename "${patch}")"
    done
}

# Create a .deb package from an installed DESTDIR
make_deb() {
    local pkg_name="$1"
    local pkg_version="$2"
    local pkg_desc="$3"
    local pkg_depends="${4:-}"
    local destdir="$5"

    local deb_dir="${destdir}"
    mkdir -p "${deb_dir}/DEBIAN"
    cat > "${deb_dir}/DEBIAN/control" <<EOF
Package: ${pkg_name}
Version: ${pkg_version}
Architecture: arm64
Maintainer: Rockchip GStreamer Build <build@local>
Description: ${pkg_desc}
${pkg_depends:+Depends: ${pkg_depends}}
EOF

    # Fix permissions
    find "${deb_dir}" -type d -exec chmod 755 {} \;

    local deb_file="${DEBS_DIR}/${pkg_name}_${pkg_version}_arm64.deb"
    dpkg-deb --build "${deb_dir}" "${deb_file}"
    log "Created: ${deb_file}"
}

# Install a .deb into the chroot
install_deb_to_chroot() {
    local deb_file="$1"
    local deb_basename="$(basename "${deb_file}")"
    cp "${deb_file}" "${CHROOT_DIR}/tmp/${deb_basename}"
    chroot_exec "dpkg -i /tmp/${deb_basename}"
    rm -f "${CHROOT_DIR}/tmp/${deb_basename}"
}

# Build a GStreamer component from tarball + patches
# Arguments: component_name tarball_name patch_subdir pkg_name pkg_version pkg_desc [extra_meson_opts] [pkg_depends]
build_gst_component() {
    local component="$1"
    local tarball_name="$2"
    local patch_subdir="$3"
    local pkg_name="$4"
    local pkg_version="$5"
    local pkg_desc="$6"
    local extra_meson_opts="${7:-}"
    local pkg_depends="${8:-}"

    local tarball="${PACKAGES_DIR}/${tarball_name}-${GST_VERSION}.tar.xz"
    local src="${SOURCES_DIR}/${tarball_name}-${GST_VERSION}"
    local patch_dir="${PATCHES_BASE}/${patch_subdir}_${GST_PATCH_VERSION}"
    local chroot_build="/build"

    # Extract source and apply patches (only on first extraction)
    if [ ! -d "${src}" ]; then
        if [ -f "${tarball}" ]; then
            log "Extracting ${tarball_name}-${GST_VERSION}.tar.xz..."
            tar xf "${tarball}" -C "${SOURCES_DIR}"
        else
            local url="https://gstreamer.freedesktop.org/src/${tarball_name}/${tarball_name}-${GST_VERSION}.tar.xz"
            log "Downloading ${tarball_name}-${GST_VERSION}.tar.xz..."
            wget -q "${url}" -O "${SOURCES_DIR}/${tarball_name}-${GST_VERSION}.tar.xz"
            tar xf "${SOURCES_DIR}/${tarball_name}-${GST_VERSION}.tar.xz" -C "${SOURCES_DIR}"
        fi
        # Initialize git repo for patch application
        (cd "${src}" && git init && git config user.email "build@local" && git config user.name "Build" && git add -A && git commit -m "initial" --quiet)

        # Apply patches (inside extraction block to avoid re-application)
        apply_patches "${src}" "${patch_dir}"
    fi

    # Build in chroot
    sudo mkdir -p "${CHROOT_DIR}${chroot_build}"
    sudo mount --bind "${WORK_DIR}" "${CHROOT_DIR}${chroot_build}" 2>/dev/null || true

    local build_subdir="build/${component}"
    rm -rf "${BUILD_DIR}/${component}"

    chroot_exec "cd ${chroot_build} && \
        meson setup ${build_subdir} sources/${tarball_name}-${GST_VERSION} \
            --prefix=/usr \
            --buildtype=release \
            --wrap-mode=nodownload \
            ${extra_meson_opts} && \
        meson compile -C ${build_subdir}"

    # Install
    local destdir="${BUILD_DIR}/${component}-install"
    rm -rf "${destdir}"
    chroot_exec "cd ${chroot_build} && \
        DESTDIR=${chroot_build}/build/${component}-install meson install -C ${build_subdir}"

    # Create .deb
    make_deb "${pkg_name}" "${pkg_version}" "${pkg_desc}" "${pkg_depends}" "${destdir}"

    # Install into chroot
    install_deb_to_chroot "${DEBS_DIR}/${pkg_name}_${pkg_version}_arm64.deb"

    sudo umount "${CHROOT_DIR}${chroot_build}" 2>/dev/null || true
}

# ============================================================
# CLI parsing
# ============================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  build [--from <phase>] [--only <phase>]   Build .deb packages
  clean [--all]                             Clean build artifacts
  status                                    Show build status

Phase names:
  setup, mpp, librga, gstreamer, plugins-base, plugins-good, plugins-bad, gst-rockchip
EOF
    exit 1
}

CMD="${1:-}"
shift || true

case "${CMD}" in
    build)
        START_PHASE=0
        END_PHASE=7
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --from)
                    phase_name="${2:?--from requires a phase name}"
                    START_PHASE="${PHASE_MAP[$phase_name]:-}"
                    [[ -z "$START_PHASE" ]] && err "Unknown phase: $phase_name"
                    shift 2
                    ;;
                --only)
                    phase_name="${2:?--only requires a phase name}"
                    START_PHASE="${PHASE_MAP[$phase_name]:-}"
                    END_PHASE="$START_PHASE"
                    [[ -z "$START_PHASE" ]] && err "Unknown phase: $phase_name"
                    shift 2
                    ;;
                *) err "Unknown option: $1" ;;
            esac
        done
        ;;
    clean)
        if [[ "${1:-}" == "--all" ]]; then
            log "Cleaning everything including chroot..."
            chroot_umount
            sudo rm -rf "${WORK_DIR}"
        else
            log "Cleaning build artifacts..."
            rm -rf "${BUILD_DIR}" "${DEBS_DIR}"
        fi
        exit 0
        ;;
    status)
        echo "=== Build Status ==="
        echo "Work dir: ${WORK_DIR}"
        echo ""
        echo "Chroot: $([ -d "${CHROOT_DIR}/usr" ] && echo 'READY' || echo 'NOT CREATED')"
        echo ""
        echo "Generated .deb packages:"
        if [ -d "${DEBS_DIR}" ]; then
            ls -lh "${DEBS_DIR}"/*.deb 2>/dev/null || echo "  (none)"
        else
            echo "  (none)"
        fi
        exit 0
        ;;
    "") usage ;;
    *) err "Unknown command: ${CMD}" ;;
esac

# ============================================================
# Phase functions
# ============================================================

phase_0_setup() {
    log_phase 0 "Setting up ARM64 chroot"

    # Check host prerequisites
    for cmd in debootstrap qemu-aarch64-static; do
        command -v "$cmd" >/dev/null 2>&1 || \
            err "$cmd not found. Install: sudo apt install qemu-user-static debootstrap binfmt-support"
    done

    mkdir -p "${SOURCES_DIR}" "${BUILD_DIR}" "${DEBS_DIR}"

    if [ -d "${CHROOT_DIR}/usr" ]; then
        log "Chroot already exists, skipping creation"
    else
        log "Creating ARM64 chroot (this takes a few minutes)..."
        sudo debootstrap --arch=arm64 noble "${CHROOT_DIR}" http://ports.ubuntu.com/ubuntu-ports
    fi

    chroot_mount

    # Configure apt sources for universe
    sudo tee "${CHROOT_DIR}/etc/apt/sources.list" > /dev/null <<'SOURCES'
deb http://ports.ubuntu.com/ubuntu-ports noble main universe
deb http://ports.ubuntu.com/ubuntu-ports noble-updates main universe
deb http://ports.ubuntu.com/ubuntu-ports noble-security main universe
SOURCES

    chroot_exec "apt-get update"
    chroot_exec "DEBIAN_FRONTEND=noninteractive apt-get install -y \
        build-essential meson cmake ninja-build pkg-config git \
        libdrm-dev libglib2.0-dev libgudev-1.0-dev \
        libx11-dev libxext-dev libxv-dev \
        libwayland-dev wayland-protocols \
        libegl-dev libgles-dev libgl-dev \
        libpango1.0-dev libcairo2-dev \
        libasound2-dev libpulse-dev \
        libsoup-3.0-dev libjson-glib-dev \
        libflac-dev libvorbis-dev libopus-dev \
        iso-codes libtheora-dev libogg-dev \
        libvisual-0.4-dev libcdparanoia-dev \
        flex bison nasm \
        dpkg-dev fakeroot"

    log "Phase 0 complete: chroot ready"
}

phase_1_mpp() {
    log_phase 1 "Building rockchip-mpp"

    local src="${SOURCES_DIR}/rockchip-mpp"
    local chroot_src="/build/sources/rockchip-mpp"
    local destdir="${BUILD_DIR}/mpp-install"
    local destdir_dev="${BUILD_DIR}/mpp-dev-install"

    # Clone source
    if [ ! -d "${src}/.git" ]; then
        log "Cloning rockchip-mpp..."
        git clone --branch "${MPP_BRANCH}" --single-branch "${MIRRORS_GIT}" "${src}"
        (cd "${src}" && git checkout "${MPP_SRCREV}")
    fi

    # Bind source into chroot
    local chroot_build="/build"
    sudo mkdir -p "${CHROOT_DIR}${chroot_build}"
    sudo mount --bind "${WORK_DIR}" "${CHROOT_DIR}${chroot_build}" 2>/dev/null || true

    # Build inside chroot
    rm -rf "${BUILD_DIR}/mpp"
    chroot_exec "cd ${chroot_build}/sources/rockchip-mpp && \
        mkdir -p ${chroot_build}/build/mpp && \
        cd ${chroot_build}/build/mpp && \
        CFLAGS='-D_LARGEFILE64_SOURCE -D_FILE_OFFSET_BITS=64' \
        cmake ${chroot_src} -DRKPLATFORM=ON -DHAVE_DRM=ON \
            -DCMAKE_INSTALL_PREFIX=/usr \
            -DCMAKE_BUILD_TYPE=Release && \
        make -j\$(nproc)"

    # Install to destdir for runtime package
    rm -rf "${destdir}" "${destdir_dev}"
    chroot_exec "cd ${chroot_build}/build/mpp && \
        DESTDIR=${chroot_build}/build/mpp-install make install"

    # Split into runtime and dev packages
    mkdir -p "${destdir_dev}/usr/lib/aarch64-linux-gnu/pkgconfig"
    mkdir -p "${destdir_dev}/usr/include"

    # Move headers and pkgconfig to dev
    if [ -d "${destdir}/usr/include" ]; then
        cp -a "${destdir}/usr/include" "${destdir_dev}/usr/"
        rm -rf "${destdir}/usr/include"
    fi
    # Move .so symlinks (not versioned) and pkgconfig to dev
    find "${destdir}/usr" -name "*.pc" -exec mv {} "${destdir_dev}/usr/lib/aarch64-linux-gnu/pkgconfig/" \; 2>/dev/null || true
    if [ -d "${destdir}/usr/lib/pkgconfig" ]; then
        mv "${destdir}/usr/lib/pkgconfig"/* "${destdir_dev}/usr/lib/aarch64-linux-gnu/pkgconfig/" 2>/dev/null || true
        rm -rf "${destdir}/usr/lib/pkgconfig"
    fi

    # Create .deb packages
    make_deb "rockchip-mpp" "1.3.9" "Rockchip Media Process Platform" "libdrm2" "${destdir}"
    make_deb "rockchip-mpp-dev" "1.3.9" "Rockchip MPP development files" "rockchip-mpp (= 1.3.9)" "${destdir_dev}"

    # Install into chroot for subsequent phases
    install_deb_to_chroot "${DEBS_DIR}/rockchip-mpp_1.3.9_arm64.deb"
    install_deb_to_chroot "${DEBS_DIR}/rockchip-mpp-dev_1.3.9_arm64.deb"

    sudo umount "${CHROOT_DIR}${chroot_build}" 2>/dev/null || true

    log "Phase 1 complete: rockchip-mpp .debs created"
}

phase_2_librga() {
    log_phase 2 "Building rockchip-librga"

    local src="${SOURCES_DIR}/rockchip-librga"
    local chroot_build="/build"

    # Clone source
    if [ ! -d "${src}/.git" ]; then
        log "Cloning rockchip-librga..."
        git clone --branch "${LIBRGA_BRANCH}" --single-branch "${MIRRORS_GIT}" "${src}"
        (cd "${src}" && git checkout "${LIBRGA_SRCREV}")
    fi

    sudo mkdir -p "${CHROOT_DIR}${chroot_build}"
    sudo mount --bind "${WORK_DIR}" "${CHROOT_DIR}${chroot_build}" 2>/dev/null || true

    # Build
    rm -rf "${BUILD_DIR}/librga"
    chroot_exec "cd ${chroot_build} && \
        meson setup build/librga sources/rockchip-librga \
            --prefix=/usr \
            --buildtype=release \
            -Dlibdrm=true && \
        meson compile -C build/librga"

    # Install
    local destdir="${BUILD_DIR}/librga-install"
    local destdir_dev="${BUILD_DIR}/librga-dev-install"
    rm -rf "${destdir}" "${destdir_dev}"

    chroot_exec "cd ${chroot_build} && \
        DESTDIR=${chroot_build}/build/librga-install meson install -C build/librga"

    # Split runtime/dev
    mkdir -p "${destdir_dev}/usr"
    if [ -d "${destdir}/usr/include" ]; then
        cp -a "${destdir}/usr/include" "${destdir_dev}/usr/"
        rm -rf "${destdir}/usr/include"
    fi
    # Move pkgconfig and .so symlinks to dev
    mkdir -p "${destdir_dev}/usr/lib"
    find "${destdir}/usr" -path "*/pkgconfig" -type d -exec mv {} "${destdir_dev}/usr/lib/" \; 2>/dev/null || true

    make_deb "librga2" "2.1.0" "Rockchip RGA 2D acceleration library" "libdrm2" "${destdir}"
    make_deb "librga-dev" "2.1.0" "Rockchip RGA development files" "librga2 (= 2.1.0)" "${destdir_dev}"

    install_deb_to_chroot "${DEBS_DIR}/librga2_2.1.0_arm64.deb"
    install_deb_to_chroot "${DEBS_DIR}/librga-dev_2.1.0_arm64.deb"

    sudo umount "${CHROOT_DIR}${chroot_build}" 2>/dev/null || true

    log "Phase 2 complete: librga .debs created"
}

phase_3_gstreamer() {
    log_phase 3 "Building gstreamer1.0"

    build_gst_component \
        "gstreamer" \
        "gstreamer" \
        "gstreamer1.0" \
        "libgstreamer1.0-0" \
        "${GST_VERSION}" \
        "GStreamer core library (Rockchip patched)" \
        "" \
        "libglib2.0-0"

    log "Phase 3 complete: gstreamer1.0 .deb created"
}

phase_4_plugins_base() {
    log_phase 4 "Building gst-plugins-base"

    build_gst_component \
        "plugins-base" \
        "gst-plugins-base" \
        "gstreamer1.0-plugins-base" \
        "gstreamer1.0-plugins-base" \
        "${GST_VERSION}" \
        "GStreamer base plugins (Rockchip patched, RGA accelerated)" \
        "" \
        "libgstreamer1.0-0, librga2"

    log "Phase 4 complete: gst-plugins-base .deb created"
}

phase_5_plugins_good() {
    log_phase 5 "Building gst-plugins-good"

    build_gst_component \
        "plugins-good" \
        "gst-plugins-good" \
        "gstreamer1.0-plugins-good" \
        "gstreamer1.0-plugins-good" \
        "${GST_VERSION}" \
        "GStreamer good plugins (Rockchip patched, V4L2/RGA enhanced)" \
        "" \
        "gstreamer1.0-plugins-base, librga2"

    log "Phase 5 complete: gst-plugins-good .deb created"
}

phase_6_plugins_bad() {
    log_phase 6 "Building gst-plugins-bad"

    build_gst_component \
        "plugins-bad" \
        "gst-plugins-bad" \
        "gstreamer1.0-plugins-bad" \
        "gstreamer1.0-plugins-bad" \
        "${GST_VERSION}" \
        "GStreamer bad plugins (Rockchip patched, KMS/Wayland enhanced)" \
        "" \
        "gstreamer1.0-plugins-base"

    log "Phase 6 complete: gst-plugins-bad .deb created"
}

phase_7_gst_rockchip() {
    log_phase 7 "Building gstreamer1.0-rockchip"

    local src="${SOURCES_DIR}/gstreamer1.0-rockchip"
    local chroot_build="/build"

    # Clone source
    if [ ! -d "${src}/.git" ]; then
        log "Cloning gstreamer1.0-rockchip..."
        git clone --branch "${GST_ROCKCHIP_BRANCH}" --single-branch "${MIRRORS_GIT}" "${src}"
        (cd "${src}" && git checkout "${GST_ROCKCHIP_SRCREV}")
    fi

    # Build in chroot
    sudo mkdir -p "${CHROOT_DIR}${chroot_build}"
    sudo mount --bind "${WORK_DIR}" "${CHROOT_DIR}${chroot_build}" 2>/dev/null || true

    rm -rf "${BUILD_DIR}/gst-rockchip"
    chroot_exec "cd ${chroot_build} && \
        meson setup build/gst-rockchip sources/gstreamer1.0-rockchip \
            --prefix=/usr \
            --buildtype=release \
            -Drockchipmpp=enabled \
            -Drga=enabled \
            -Dkmssrc=enabled && \
        meson compile -C build/gst-rockchip"

    # Install
    local destdir="${BUILD_DIR}/gst-rockchip-install"
    rm -rf "${destdir}"
    chroot_exec "cd ${chroot_build} && \
        DESTDIR=${chroot_build}/build/gst-rockchip-install meson install -C build/gst-rockchip"

    make_deb \
        "gstreamer1.0-rockchip" \
        "1.0-1" \
        "GStreamer Rockchip plugins (MPP hardware codec, RGA, KMS source)" \
        "rockchip-mpp, librga2, gstreamer1.0-plugins-base" \
        "${destdir}"

    sudo umount "${CHROOT_DIR}${chroot_build}" 2>/dev/null || true

    log "Phase 7 complete: gstreamer1.0-rockchip .deb created"
}

# ============================================================
# Execute phases
# ============================================================

mkdir -p "${WORK_DIR}"
chroot_mount

for phase_num in $(seq "${START_PHASE}" "${END_PHASE}"); do
    phase_name="${PHASE_NAMES[$phase_num]}"
    case $phase_num in
        0) phase_0_setup ;;
        1) phase_1_mpp ;;
        2) phase_2_librga ;;
        3) phase_3_gstreamer ;;
        4) phase_4_plugins_base ;;
        5) phase_5_plugins_good ;;
        6) phase_6_plugins_bad ;;
        7) phase_7_gst_rockchip ;;
    esac
done

log ""
log "Build complete! .deb packages are in: ${DEBS_DIR}"
ls -lh "${DEBS_DIR}"/*.deb 2>/dev/null
