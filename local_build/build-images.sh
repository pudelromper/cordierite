#!/usr/bin/bash
# Build, rechunk, test, push and sign Cordierite images without GitHub Actions.
# Mirrors .github/workflows/build.yml step for step.
#
# Usage: build-images.sh [image ...]      (defaults to CORDIERITE_IMAGES)

set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
need buildah podman skopeo jq git
if [[ "${CORDIERITE_NO_PUSH:-0}" != "1" ]]; then
    need cosign
    [[ -f "${COSIGN_KEY:-}" ]] || die "COSIGN_KEY is not set or does not exist (${COSIGN_KEY:-unset})"
    if [[ -n "${COSIGN_PASSWORD_FILE:-}" && -z "${COSIGN_PASSWORD:-}" ]]; then
        COSIGN_PASSWORD="$(<"${COSIGN_PASSWORD_FILE}")"
        export COSIGN_PASSWORD
    fi
fi

images=("$@")
if [[ ${#images[@]} -eq 0 ]]; then
    read -r -a images <<<"${CORDIERITE_IMAGES}"
fi

WORK_DIR="$(mktemp -d "${CORDIERITE_STATE_DIR}/build-XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT
cd "${PROJECT_ROOT}"

#
# Version tag for the whole run (build.yml "version" job)
#
run_version() {
    local version="${FEDORA_VERSION}.$(date +%Y%m%d)"
    case "${CORDIERITE_TRACK}" in
        testing | unstable) version="${CORDIERITE_TRACK}-${version}" ;;
    esac

    # A tag taken by any image is taken for every image, so the run lands on one tag.
    declare -A taken
    local image t
    for image in "${images[@]}"; do
        while read -r t; do
            [[ -n "${t}" ]] && taken["${t}"]=1
        done < <(skopeo list-tags "docker://${CORDIERITE_REGISTRY}/${CORDIERITE_VENDOR}/${image}" 2>/dev/null | jq -r '.Tags[]' || true)
    done
    if [[ -v taken["${version}"] ]]; then
        local build=1
        while [[ -v taken["${version}.${build}"] ]]; do
            build=$((build + 1))
        done
        version="${version}.${build}"
    fi
    echo "${version}"
}
RUN_VERSION="$(run_version)"
log "run version: ${RUN_VERSION} (track ${CORDIERITE_TRACK}, commit ${GIT_SHA_SHORT})"

#
# Upstream base tag (build.yml "Pull Images and find versions")
#
base_version() {
    local base_image="$1" upstream_tag
    podman pull -q "${base_image}" >/dev/null
    upstream_tag="$(skopeo inspect "docker://${base_image}" | jq -r '.Labels["org.opencontainers.image.version"]')"
    [[ -n "${upstream_tag}" && "${upstream_tag}" != "null" ]] || die "base image ${base_image} has no version label"
    echo "${upstream_tag%\.[0-9]}"
}

build_one() {
    local image="$1"
    image_vars "${image}"
    log "==== ${image}: target ${CONTAINER_TARGET}, kernel ${IMAGE_KERNEL_FLAVOR} ${IMAGE_KERNEL_VERSION}, nvidia ${NVIDIA_FLAVOR}"

    local upstream_tag version_tag version_pretty
    upstream_tag="$(base_version "${BASE_IMAGE}")"
    case "${CORDIERITE_TRACK}" in
        unstable) version_tag="unstable-${upstream_tag}"; version_pretty="Unstable (F${upstream_tag}, #${GIT_SHA_SHORT})" ;;
        testing)  version_tag="testing-${upstream_tag}";  version_pretty="Testing (F${upstream_tag}, #${GIT_SHA_SHORT})" ;;
        *)        version_tag="${upstream_tag}";          version_pretty="Stable (F${upstream_tag})" ;;
    esac

    local raw="localhost/cordierite-raw-${image}" chunked="localhost/cordierite-chunked-${image}"
    local args="${WORK_DIR}/${image}.build_args"
    cat >"${args}" <<ARGS
BASE_IMAGE_NAME=${BASE_IMAGE_NAME}
FEDORA_VERSION=${FEDORA_VERSION}
BASE_IMAGE=${BASE_IMAGE}
IMAGE_NAME=${image}
IMAGE_VENDOR=${CORDIERITE_VENDOR}
IMAGE_REGISTRY=${CORDIERITE_REGISTRY}
IMAGE_BRANCH=${CORDIERITE_BRANCH}
KERNEL_FLAVOR=${IMAGE_KERNEL_FLAVOR}
KERNEL_VERSION=${IMAGE_KERNEL_VERSION}
NVIDIA_FLAVOR=${NVIDIA_FLAVOR}
NVIDIA_BASE=${NVIDIA_BASE}
SHA_HEAD_SHORT=${GIT_SHA_SHORT}
VERSION_TAG=${version_tag}
VERSION_PRETTY=${version_pretty}
ARCH=${CORDIERITE_ARCH}
ARGS

    #
    # Build
    #
    local secret=()
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        secret=(--secret "id=GITHUB_TOKEN,env=GITHUB_TOKEN")
    fi
    log "${image}: buildah build"
    buildah build \
        --target "${CONTAINER_TARGET}" \
        --build-arg-file "${args}" \
        "${secret[@]}" \
        --tag "${raw}" .

    #
    # Labels (build.yml "Apply Labels"); keep in sync with the workflow
    #
    local kver
    kver="$(podman run --rm "${raw}" rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core)"
    local labels_file="${WORK_DIR}/${image}.labels"
    cat >"${labels_file}" <<LABELS
org.opencontainers.image.description=Cordierite is a custom Fedora Atomic image built on Bazzite, tuned for everyday desktop use with security hardening and a poodle on top.
org.opencontainers.image.licenses=Apache-2.0
org.opencontainers.image.revision=$(git rev-parse HEAD)
org.opencontainers.image.source=https://github.com/pudelromper/cordierite
org.opencontainers.image.title=Cordierite
org.opencontainers.image.vendor=pudelromper
org.opencontainers.image.url=https://github.com/pudelromper/cordierite
org.opencontainers.image.version=${RUN_VERSION}
org.opencontainers.image.created=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
ostree.bootable=true
ostree.linux=${kver}
LABELS

    #
    # Rechunk (build.yml "Run Rechunker")
    #
    log "${image}: rechunk"
    buildah unshare bash -euo pipefail -c '
        container=$(buildah from "$1")
        mnt=$(buildah mount "$container")
        rm -rf "$mnt"/run/.* "$mnt"/run/* "$mnt"/tmp/.* "$mnt"/tmp/* || true
        buildah umount "$container"
        buildah commit --identity-label=false --rm "$container" "$1"
    ' _ "${raw}"

    local rechunk_dir="${WORK_DIR}/rechunk-${image}"
    mkdir -p "${rechunk_dir}"
    local label_args=() line
    while IFS= read -r line; do
        [[ -n "${line}" ]] && label_args+=(--label "${line}")
    done <"${labels_file}"

    podman run --rm \
        --pull=never \
        --privileged \
        --mount="type=image,src=${raw},target=/rpm-ostree" \
        --volume "${rechunk_dir}:/run/out:Z" \
        --entrypoint /usr/bin/rpm-ostree \
        "${raw}" \
        compose build-chunked-oci \
        --bootc --max-layers 127 --format-version 2 \
        "${label_args[@]}" \
        --rootfs /rpm-ostree --output oci-archive:/run/out/chunked.oci
    podman rmi -f "${raw}" >/dev/null
    local chunked_id
    chunked_id="$(podman pull -q "oci-archive:${rechunk_dir}/chunked.oci")"
    podman tag "${chunked_id}" "${chunked}"
    rm -rf "${rechunk_dir}"

    #
    # Smoke tests
    #
    if [[ "${CORDIERITE_SKIP_TESTS:-0}" != "1" ]]; then
        if command -v dgoss >/dev/null 2>&1 && command -v goss >/dev/null 2>&1; then
            log "${image}: goss tests"
            tests/dgoss/dgoss-tests.sh tests/dgoss/tests.d "containers-storage:${chunked}"
        else
            log "${image}: goss/dgoss not installed, skipping smoke tests (set CORDIERITE_SKIP_TESTS=1 to silence)"
        fi
    fi

    if [[ "${CORDIERITE_NO_PUSH:-0}" == "1" ]]; then
        log "${image}: CORDIERITE_NO_PUSH=1, leaving ${chunked} in local storage"
        return 0
    fi

    #
    # Tags (build.yml "Generate tags")
    #
    local alias_tags
    case "${CORDIERITE_TRACK}" in
        unstable) alias_tags=("unstable" "unstable-${FEDORA_VERSION}") ;;
        testing)  alias_tags=("testing" "testing-${FEDORA_VERSION}") ;;
        *)        alias_tags=("stable-${RUN_VERSION}" "latest" "stable" "stable-${FEDORA_VERSION}") ;;
    esac

    #
    # Push
    #
    log "${image}: push ${OUTPUT_IMAGE}:${RUN_VERSION}"
    local digestfile="${WORK_DIR}/${image}.digest"
    retry 3 15 podman push --digestfile="${digestfile}" "${chunked}" "docker://${OUTPUT_IMAGE}:${RUN_VERSION}"
    local digest
    digest="$(<"${digestfile}")"
    [[ -n "${digest}" ]] || die "${image}: push reported success but wrote no digest"
    local tag
    for tag in "${alias_tags[@]}"; do
        retry 3 15 skopeo copy "docker://${OUTPUT_IMAGE}@${digest}" "docker://${OUTPUT_IMAGE}:${tag}"
        log "${image}: tagged ${OUTPUT_IMAGE}:${tag}"
    done

    #
    # Sign
    #
    log "${image}: cosign sign ${OUTPUT_IMAGE}@${digest}"
    local sign_flags=()
    mapfile -t sign_flags < <(cosign_sign_flags)
    cosign sign "${sign_flags[@]}" "${OUTPUT_IMAGE}@${digest}"

    podman rmi -f "${chunked}" >/dev/null
    log "${image}: done -> ${OUTPUT_IMAGE}:${RUN_VERSION} (${digest})"
}

failed=()
for image in "${images[@]}"; do
    if ! build_one "${image}"; then
        log "${image}: FAILED"
        failed+=("${image}")
    fi
done

if [[ ${#failed[@]} -gt 0 ]]; then
    die "failed images: ${failed[*]}"
fi
log "all images published with version ${RUN_VERSION}"
