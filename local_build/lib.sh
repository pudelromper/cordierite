#!/usr/bin/bash
# Shared helpers for the local (non-GitHub) release pipeline.
# Sourced by build-images.sh, build-iso.sh and release.sh.

set -euo pipefail

LOCAL_BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${LOCAL_BUILD_DIR}/.." && pwd)"
MATRIX_FILE="${PROJECT_ROOT}/.github/workflows/build.yml"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
need() {
    local t
    for t in "$@"; do
        command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
    done
}

# Read a scalar from the CI matrix so the kernel pin lives in one place.
# The first occurrence is the default include entry; the LTS variant follows
# the "- image: cordierite-nvidia" entry.
matrix_value() {
    awk -v k="$1:" '{ for (i = 1; i <= NF; i++) if ($i == k) { print $(i + 1); exit } }' "${MATRIX_FILE}"
}
matrix_value_lts() {
    awk -v k="$1:" '/- image: cordierite-nvidia$/ { f = 1 } f { for (i = 1; i <= NF; i++) if ($i == k) { print $(i + 1); exit } }' "${MATRIX_FILE}"
}

# Configuration: first file found wins. CORDIERITE_ENV overrides everything.
load_env() {
    local f
    for f in "${CORDIERITE_ENV:-}" /etc/cordierite/build.env "${LOCAL_BUILD_DIR}/build.env"; do
        [[ -n "${f}" && -f "${f}" ]] || continue
        set -a
        # shellcheck disable=SC1090
        . "${f}"
        set +a
        log "configuration: ${f}"
        break
    done

    CORDIERITE_REGISTRY="${CORDIERITE_REGISTRY:-ghcr.io}"
    CORDIERITE_VENDOR="${CORDIERITE_VENDOR:-pudelromper}"
    CORDIERITE_IMAGES="${CORDIERITE_IMAGES:-cordierite cordierite-deck cordierite-nvidia cordierite-nvidia-open}"
    CORDIERITE_STATE_DIR="${CORDIERITE_STATE_DIR:-/var/lib/cordierite}"
    CORDIERITE_ISO_DIR="${CORDIERITE_ISO_DIR:-${CORDIERITE_STATE_DIR}/iso}"
    CORDIERITE_ARCH="${CORDIERITE_ARCH:-x86_64}"

    FEDORA_VERSION="${FEDORA_VERSION:-$(matrix_value fedora_version)}"
    KERNEL_FLAVOR="${KERNEL_FLAVOR:-$(matrix_value kernel_flavor)}"
    KERNEL_VERSION="${KERNEL_VERSION:-$(matrix_value kernel_version)}"
    KERNEL_FLAVOR_LTS="${KERNEL_FLAVOR_LTS:-$(matrix_value_lts kernel_flavor)}"
    KERNEL_VERSION_LTS="${KERNEL_VERSION_LTS:-$(matrix_value_lts kernel_version)}"
    [[ -n "${FEDORA_VERSION}" && -n "${KERNEL_FLAVOR}" && -n "${KERNEL_VERSION}" ]] ||
        die "could not read the image matrix from ${MATRIX_FILE}"

    local git_branch
    git_branch="$(git -C "${PROJECT_ROOT}" branch --show-current 2>/dev/null || true)"
    CORDIERITE_BRANCH="${CORDIERITE_BRANCH:-${git_branch:-main}}"
    case "${CORDIERITE_BRANCH}" in
        testing | unstable) CORDIERITE_TRACK="${CORDIERITE_BRANCH}" ;;
        *) CORDIERITE_TRACK="stable" ;;
    esac

    GIT_SHA_SHORT="$(git -C "${PROJECT_ROOT}" rev-parse --short=7 HEAD 2>/dev/null || echo unknown)"

    mkdir -p "${CORDIERITE_STATE_DIR}" "${CORDIERITE_ISO_DIR}"
    export CORDIERITE_REGISTRY CORDIERITE_VENDOR CORDIERITE_IMAGES CORDIERITE_STATE_DIR CORDIERITE_ISO_DIR \
        CORDIERITE_ARCH FEDORA_VERSION KERNEL_FLAVOR KERNEL_VERSION KERNEL_FLAVOR_LTS KERNEL_VERSION_LTS \
        CORDIERITE_BRANCH CORDIERITE_TRACK GIT_SHA_SHORT
}

# Per-image derived values, mirroring the "Define base variables" step of build.yml.
image_vars() {
    local image="$1"
    BASE_IMAGE_NAME="kinoite"
    [[ "${image}" == *gnome* ]] && BASE_IMAGE_NAME="silverblue"

    if [[ "${image}" == *deck* && "${image}" == *nvidia* ]]; then
        CONTAINER_TARGET="cordierite-nvidia"; NVIDIA_BASE="cordierite-deck"; INSTALL_NVIDIA=true
    elif [[ "${image}" == *nvidia* ]]; then
        CONTAINER_TARGET="cordierite-nvidia"; NVIDIA_BASE="cordierite"; INSTALL_NVIDIA=true
    elif [[ "${image}" == *deck* ]]; then
        CONTAINER_TARGET="cordierite-deck"; NVIDIA_BASE="cordierite-deck"; INSTALL_NVIDIA=false
    else
        CONTAINER_TARGET="cordierite"; NVIDIA_BASE="cordierite"; INSTALL_NVIDIA=false
    fi

    if [[ "${image}" == *nvidia-open || "${image}" == *-deck-nvidia* ]]; then
        NVIDIA_FLAVOR="nvidia-open"
    else
        NVIDIA_FLAVOR="nvidia-lts"
    fi

    # Only the plain nvidia image rides the LTS kernel, as in the CI matrix.
    if [[ "${image}" == "cordierite-nvidia" ]]; then
        IMAGE_KERNEL_FLAVOR="${KERNEL_FLAVOR_LTS}"; IMAGE_KERNEL_VERSION="${KERNEL_VERSION_LTS}"
    else
        IMAGE_KERNEL_FLAVOR="${KERNEL_FLAVOR}"; IMAGE_KERNEL_VERSION="${KERNEL_VERSION}"
    fi

    BASE_IMAGE="ghcr.io/ublue-os/${BASE_IMAGE_NAME}-main:${FEDORA_VERSION}"
    OUTPUT_IMAGE="${CORDIERITE_REGISTRY}/${CORDIERITE_VENDOR}/${image}"
}

# The base ("non-deck", "non-nvidia") image is the live ISO runtime.
nondeck_ref() {
    local ref="$1"
    ref="${ref/-deck/}"
    ref="${ref/-nvidia-open/}"
    ref="${ref/-nvidia/}"
    echo "${ref}"
}

retry() {
    local attempts="$1" delay="$2" n=1
    shift 2
    until "$@"; do
        if (( n >= attempts )); then
            return 1
        fi
        log "attempt ${n}/${attempts} failed, retrying in ${delay}s: $*"
        sleep "${delay}"
        n=$((n + 1))
    done
}

cosign_sign_flags() {
    # cosign 3 needs --use-signing-config=false to keep using a plain key;
    # cosign 2 does not know the flag.
    local flags=(-y --key "${COSIGN_KEY}" --new-bundle-format=false)
    if cosign sign --help 2>&1 | grep -q -- '--use-signing-config'; then
        flags+=(--use-signing-config=false)
    fi
    printf '%s\n' "${flags[@]}"
}
