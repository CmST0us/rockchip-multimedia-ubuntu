#!/bin/bash
set -euo pipefail

# ============================================================
# Rockchip GStreamer .deb Build Script
# Builds ARM64 .deb packages for Rockchip multimedia stack
# using QEMU user-mode emulation in ARM64 Docker container
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/build-gst-rockchip"
SOURCES_DIR="${WORK_DIR}/sources"
BUILD_DIR="${WORK_DIR}/build"
DEBS_DIR="${WORK_DIR}/debs"
YOCTO_DIR="${SCRIPT_DIR}/yocto-rockchip"
YOCTO_GIT="https://gitlab-r.eric3u.xyz:21443/argon/meta-rockchip.git"
YOCTO_BRANCH="scarthgap-vendor"
PACKAGES_DIR="${YOCTO_DIR}/packages"
PATCHES_BASE="${YOCTO_DIR}/recipes-multimedia/gstreamer"

# Docker settings
DOCKER_IMAGE_NAME="rockchip-gstreamer-builder"
DOCKER_CONTAINER_NAME="rockchip-gstreamer-build"
DOCKERFILE_PATH="${SCRIPT_DIR}/Dockerfile.gst-builder"

# Versions
GST_VERSION="1.22.12"
GST_PATCH_VERSION="1.22.12"

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

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

container_exec() {
    docker exec -w /build "${DOCKER_CONTAINER_NAME}" /bin/bash -c "$*"
}

# Fix ownership of container-created (root-owned) files back to host user
container_chown() {
    for dir in "$@"; do
        local container_path="${dir/#${WORK_DIR}/\/build}"
        container_exec "chown -R ${HOST_UID}:${HOST_GID} '${container_path}'"
    done
}

# Remove directories that may contain root-owned files (created by Docker)
rm_docker_owned() {
    for dir in "$@"; do
        [ -d "$dir" ] || continue
        rm -rf "$dir" 2>/dev/null && continue
        local container_path="${dir/#${WORK_DIR}/\/build}"
        if docker inspect --format='{{.State.Running}}' "${DOCKER_CONTAINER_NAME}" 2>/dev/null | grep -q true; then
            container_exec "rm -rf '${container_path}'"
        else
            docker run --rm --platform linux/arm64 -v "${WORK_DIR}:/build" "${DOCKER_IMAGE_NAME}" rm -rf "${container_path}"
        fi
    done
}

ensure_container_running() {
    if ! docker inspect --format='{{.State.Running}}' "${DOCKER_CONTAINER_NAME}" 2>/dev/null | grep -q true; then
        err "Container '${DOCKER_CONTAINER_NAME}' is not running. Run 'build --only setup' first."
    fi
}

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

# Install a .deb into the container (file accessible via /build volume)
install_deb_to_container() {
    local deb_file="$1"
    container_exec "dpkg -i /build/debs/$(basename "${deb_file}")"
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

    # Build in container
    local build_subdir="build/${component}"
    rm_docker_owned "${BUILD_DIR}/${component}"

    container_exec "cd /build && \
        meson setup ${build_subdir} sources/${tarball_name}-${GST_VERSION} \
            --prefix=/usr \
            --buildtype=release \
            --wrap-mode=nodownload \
            ${extra_meson_opts} && \
        meson compile -C ${build_subdir} && \
        chown -R ${HOST_UID}:${HOST_GID} ${build_subdir}"

    # Install
    local destdir="${BUILD_DIR}/${component}-install"
    rm_docker_owned "${destdir}"
    container_exec "cd /build && \
        DESTDIR=/build/build/${component}-install meson install -C ${build_subdir} && \
        chown -R ${HOST_UID}:${HOST_GID} /build/build/${component}-install"

    # Create .deb
    make_deb "${pkg_name}" "${pkg_version}" "${pkg_desc}" "${pkg_depends}" "${destdir}"

    # Install into container for subsequent phases
    install_deb_to_container "${DEBS_DIR}/${pkg_name}_${pkg_version}_arm64.deb"
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
            log "Cleaning everything including Docker container and image..."
            # Remove root-owned files via container before stopping it
            rm_docker_owned "${WORK_DIR}"
            docker stop "${DOCKER_CONTAINER_NAME}" 2>/dev/null || true
            docker rm "${DOCKER_CONTAINER_NAME}" 2>/dev/null || true
            docker rmi "${DOCKER_IMAGE_NAME}" 2>/dev/null || true
        else
            log "Cleaning build artifacts..."
            rm_docker_owned "${BUILD_DIR}" "${DEBS_DIR}"
        fi
        exit 0
        ;;
    status)
        echo "=== Build Status ==="
        echo "Work dir: ${WORK_DIR}"
        echo ""
        if docker inspect --format='{{.State.Running}}' "${DOCKER_CONTAINER_NAME}" 2>/dev/null | grep -q true; then
            echo "Docker container: RUNNING (${DOCKER_CONTAINER_NAME})"
        elif docker inspect "${DOCKER_CONTAINER_NAME}" >/dev/null 2>&1; then
            echo "Docker container: STOPPED (${DOCKER_CONTAINER_NAME})"
        else
            echo "Docker container: NOT CREATED"
        fi
        if docker image inspect "${DOCKER_IMAGE_NAME}" >/dev/null 2>&1; then
            echo "Docker image: EXISTS (${DOCKER_IMAGE_NAME})"
        else
            echo "Docker image: NOT BUILT"
        fi
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
    log_phase 0 "Setting up ARM64 Docker container"

    # Check host prerequisites
    command -v docker >/dev/null 2>&1 || \
        err "docker not found. Install Docker: https://docs.docker.com/engine/install/"

    # Check QEMU binfmt_misc registration for ARM64
    if [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
        err "QEMU binfmt_misc not registered for aarch64. Install: sudo apt install qemu-user-static binfmt-support"
    fi

    # Clone yocto-rockchip (provides patches and packages)
    if [ ! -d "${YOCTO_DIR}/.git" ]; then
        log "Cloning yocto-rockchip..."
        git clone --branch "${YOCTO_BRANCH}" --single-branch "${YOCTO_GIT}" "${YOCTO_DIR}"
    fi

    # Build Docker image (idempotent, uses layer cache)
    log "Building Docker image '${DOCKER_IMAGE_NAME}'..."
    docker build --platform linux/arm64 \
        -t "${DOCKER_IMAGE_NAME}" \
        -f "${DOCKERFILE_PATH}" \
        "${SCRIPT_DIR}"

    # Start container if not already running (recreate if mounts changed)
    local need_recreate=false
    if docker inspect --format='{{.State.Running}}' "${DOCKER_CONTAINER_NAME}" 2>/dev/null | grep -q true; then
        local current_mount
        current_mount="$(docker inspect --format='{{range .Mounts}}{{if eq .Destination "/build"}}{{.Source}}{{end}}{{end}}' "${DOCKER_CONTAINER_NAME}")"
        if [[ "${current_mount}" == "${WORK_DIR}" ]]; then
            log "Container '${DOCKER_CONTAINER_NAME}' already running"
        else
            log "Container mount path changed, recreating..."
            need_recreate=true
        fi
    else
        need_recreate=true
    fi
    if [[ "${need_recreate}" == true ]]; then
        docker rm -f "${DOCKER_CONTAINER_NAME}" 2>/dev/null || true

        log "Starting container '${DOCKER_CONTAINER_NAME}'..."
        docker run -d \
            --name "${DOCKER_CONTAINER_NAME}" \
            --platform linux/arm64 \
            -v "${WORK_DIR}:/build" \
            -v "${PACKAGES_DIR}:/packages:ro" \
            -v "${PATCHES_BASE}:/patches:ro" \
            "${DOCKER_IMAGE_NAME}"
    fi

    log "Phase 0 complete: Docker container ready"
}

phase_1_mpp() {
    log_phase 1 "Building rockchip-mpp"

    local src="${SOURCES_DIR}/rockchip-mpp"
    local destdir="${BUILD_DIR}/mpp-install"
    local destdir_dev="${BUILD_DIR}/mpp-dev-install"

    # Clone source
    if [ ! -d "${src}/.git" ]; then
        log "Cloning rockchip-mpp..."
        git clone --branch "${MPP_BRANCH}" --single-branch "${MIRRORS_GIT}" "${src}"
        (cd "${src}" && git checkout "${MPP_SRCREV}")
    fi

    # Build inside container
    rm_docker_owned "${BUILD_DIR}/mpp"
    container_exec "cd /build/sources/rockchip-mpp && \
        mkdir -p /build/build/mpp && \
        cd /build/build/mpp && \
        CFLAGS='-D_LARGEFILE64_SOURCE -D_FILE_OFFSET_BITS=64' \
        cmake /build/sources/rockchip-mpp -DRKPLATFORM=ON -DHAVE_DRM=ON \
            -DCMAKE_INSTALL_PREFIX=/usr \
            -DCMAKE_BUILD_TYPE=Release && \
        make -j\$(nproc) && \
        chown -R ${HOST_UID}:${HOST_GID} /build/build/mpp"

    # Install to destdir for runtime package
    rm_docker_owned "${destdir}" "${destdir_dev}"
    container_exec "cd /build/build/mpp && \
        DESTDIR=/build/build/mpp-install make install && \
        chown -R ${HOST_UID}:${HOST_GID} /build/build/mpp-install"

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

    # Install into container for subsequent phases
    install_deb_to_container "${DEBS_DIR}/rockchip-mpp_1.3.9_arm64.deb"
    install_deb_to_container "${DEBS_DIR}/rockchip-mpp-dev_1.3.9_arm64.deb"

    log "Phase 1 complete: rockchip-mpp .debs created"
}

phase_2_librga() {
    log_phase 2 "Building rockchip-librga"

    local src="${SOURCES_DIR}/rockchip-librga"

    # Clone source
    if [ ! -d "${src}/.git" ]; then
        log "Cloning rockchip-librga..."
        git clone --branch "${LIBRGA_BRANCH}" --single-branch "${MIRRORS_GIT}" "${src}"
        (cd "${src}" && git checkout "${LIBRGA_SRCREV}")
    fi

    # Build
    rm_docker_owned "${BUILD_DIR}/librga"
    container_exec "cd /build && \
        meson setup build/librga sources/rockchip-librga \
            --prefix=/usr \
            --buildtype=release \
            -Dlibdrm=true && \
        meson compile -C build/librga && \
        chown -R ${HOST_UID}:${HOST_GID} /build/build/librga"

    # Install
    local destdir="${BUILD_DIR}/librga-install"
    local destdir_dev="${BUILD_DIR}/librga-dev-install"
    rm_docker_owned "${destdir}" "${destdir_dev}"

    container_exec "cd /build && \
        DESTDIR=/build/build/librga-install meson install -C build/librga && \
        chown -R ${HOST_UID}:${HOST_GID} /build/build/librga-install"

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

    install_deb_to_container "${DEBS_DIR}/librga2_2.1.0_arm64.deb"
    install_deb_to_container "${DEBS_DIR}/librga-dev_2.1.0_arm64.deb"

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

    # Clone source
    if [ ! -d "${src}/.git" ]; then
        log "Cloning gstreamer1.0-rockchip..."
        git clone --branch "${GST_ROCKCHIP_BRANCH}" --single-branch "${MIRRORS_GIT}" "${src}"
        (cd "${src}" && git checkout "${GST_ROCKCHIP_SRCREV}")
    fi

    # Build in container
    rm_docker_owned "${BUILD_DIR}/gst-rockchip"
    container_exec "cd /build && \
        meson setup build/gst-rockchip sources/gstreamer1.0-rockchip \
            --prefix=/usr \
            --buildtype=release \
            -Drockchipmpp=enabled \
            -Drga=enabled \
            -Dkmssrc=enabled && \
        meson compile -C build/gst-rockchip && \
        chown -R ${HOST_UID}:${HOST_GID} /build/build/gst-rockchip"

    # Install
    local destdir="${BUILD_DIR}/gst-rockchip-install"
    rm_docker_owned "${destdir}"
    container_exec "cd /build && \
        DESTDIR=/build/build/gst-rockchip-install meson install -C build/gst-rockchip && \
        chown -R ${HOST_UID}:${HOST_GID} /build/build/gst-rockchip-install"

    make_deb \
        "gstreamer1.0-rockchip" \
        "1.0-1" \
        "GStreamer Rockchip plugins (MPP hardware codec, RGA, KMS source)" \
        "rockchip-mpp, librga2, gstreamer1.0-plugins-base" \
        "${destdir}"

    log "Phase 7 complete: gstreamer1.0-rockchip .deb created"
}

# ============================================================
# Execute phases
# ============================================================

mkdir -p "${SOURCES_DIR}" "${BUILD_DIR}" "${DEBS_DIR}"

# Ensure container is running for non-setup phases
if [[ "${START_PHASE}" -gt 0 ]]; then
    ensure_container_running
fi

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
