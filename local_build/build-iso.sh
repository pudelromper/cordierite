#!/usr/bin/bash
# Build, sign and (optionally) upload live ISOs from published images.
# Mirrors .github/workflows/build_iso.yml. Needs root: the payload image is
# mounted into the ISO builder with --mount type=image from root's storage.
#
# Usage: build-iso.sh [image ...]      (defaults to CORDIERITE_IMAGES)

set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
need podman git sha256sum
[[ "$(id -u)" == "0" ]] || die "build-iso.sh must run as root (titanoboa mounts the payload image from root's container storage)"
if [[ -n "${COSIGN_KEY:-}" ]]; then
    need cosign
    if [[ -n "${COSIGN_PASSWORD_FILE:-}" && -z "${COSIGN_PASSWORD:-}" ]]; then
        COSIGN_PASSWORD="$(<"${COSIGN_PASSWORD_FILE}")"
        export COSIGN_PASSWORD
    fi
fi
if [[ -n "${RCLONE_REMOTE:-}" ]]; then
    need rclone
fi

TITANOBOA_REPO="${TITANOBOA_REPO:-https://github.com/Zeglius/titanoboa}"
TITANOBOA_REF="${TITANOBOA_REF:-revamp-pr}"
TITANOBOA_DIR="${CORDIERITE_STATE_DIR}/titanoboa"
TITANOBOA_BUILDER_IMAGE="${TITANOBOA_BUILDER_IMAGE:-quay.io/fedora/fedora:latest}"

images=("$@")
if [[ ${#images[@]} -eq 0 ]]; then
    read -r -a images <<<"${CORDIERITE_IMAGES}"
fi

# titanoboa checkout (pinned by TITANOBOA_REF)
if [[ -d "${TITANOBOA_DIR}/.git" ]]; then
    git -C "${TITANOBOA_DIR}" fetch -q origin "${TITANOBOA_REF}"
    git -C "${TITANOBOA_DIR}" checkout -q FETCH_HEAD
else
    git clone -q --depth 1 --branch "${TITANOBOA_REF}" "${TITANOBOA_REPO}" "${TITANOBOA_DIR}"
fi
[[ -f "${TITANOBOA_DIR}/build_iso.sh" ]] || die "titanoboa checkout at ${TITANOBOA_DIR} has no build_iso.sh"
log "titanoboa: $(git -C "${TITANOBOA_DIR}" rev-parse --short HEAD) (${TITANOBOA_REF})"

WORK_DIR="$(mktemp -d "${CORDIERITE_STATE_DIR}/iso-XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT
cd "${PROJECT_ROOT}"

build_one() {
    local image="$1"
    local tag="${CORDIERITE_TRACK}"
    local base="${CORDIERITE_REGISTRY}/${CORDIERITE_VENDOR}/$(nondeck_ref "${image}"):${tag}"
    local payload="${CORDIERITE_REGISTRY}/${CORDIERITE_VENDOR}/${image}:${tag}"
    local payload_local="localhost/cordierite-payload-${image}:latest"
    local flatpak_dir="kde_flatpaks"
    [[ "${image}" == *gnome* ]] && flatpak_dir="gnome_flatpaks"
    log "==== ${image}: base ${base}, payload ${payload}"

    podman pull -q "${base}" >/dev/null
    podman pull -q "${payload}" >/dev/null

    # Live environment: the base image plus anaconda, with the payload embedded
    podman build \
        --cap-add sys_admin \
        --security-opt label=disable \
        --build-arg BASE_IMAGE="${base}" \
        --build-arg INSTALL_IMAGE_PAYLOAD="${payload}" \
        --build-arg FLATPAK_DIR_SHORTNAME="${flatpak_dir}" \
        --build-arg EMBED_FLATPAKS="${EMBED_FLATPAKS:-0}" \
        -t "${payload_local}" installer/

    # titanoboa main.sh, minus its sudo
    local out="${WORK_DIR}/${image}"
    mkdir -p "${out}"
    podman run --rm -i \
        --cap-add sys_admin --security-opt label=disable \
        -v "${TITANOBOA_DIR}/build_iso.sh:/src/build_iso.sh:ro" \
        --mount "type=image,source=${payload_local},dst=/rootfs" \
        -v "${out}:/output" \
        "${TITANOBOA_BUILDER_IMAGE}" /src/build_iso.sh
    podman rmi -f "${payload_local}" >/dev/null

    local produced
    produced="$(find "${out}" -maxdepth 1 -name '*.iso' | head -1)"
    [[ -n "${produced}" ]] || die "${image}: titanoboa produced no ISO"

    local iso_name="${image}-${tag}-live-amd64.iso"
    local dest_dir="${CORDIERITE_ISO_DIR}/${tag}"
    mkdir -p "${dest_dir}"
    mv -f "${produced}" "${dest_dir}/${iso_name}"
    (cd "${dest_dir}" && sha256sum "${iso_name}" | tee "${iso_name}-CHECKSUM")

    if [[ -n "${COSIGN_KEY:-}" ]]; then
        cosign sign-blob -y --key "${COSIGN_KEY}" "${dest_dir}/${iso_name}" --output-signature "${dest_dir}/${iso_name}.sig"
    fi

    if [[ -n "${RCLONE_REMOTE:-}" ]]; then
        log "${image}: uploading to ${RCLONE_REMOTE}/${tag}/"
        local f
        for f in "${iso_name}" "${iso_name}-CHECKSUM" "${iso_name}.sig"; do
            [[ -f "${dest_dir}/${f}" ]] || continue
            retry 3 30 rclone copyto "${dest_dir}/${f}" "${RCLONE_REMOTE}/${tag}/${f}"
        done
    fi
    log "${image}: ${dest_dir}/${iso_name}"
}

failed=()
for image in "${images[@]}"; do
    if ! build_one "${image}"; then
        log "${image}: FAILED"
        failed+=("${image}")
    fi
done
[[ ${#failed[@]} -eq 0 ]] || die "failed ISOs: ${failed[*]}"
log "all ISOs built under ${CORDIERITE_ISO_DIR}/${CORDIERITE_TRACK}"
