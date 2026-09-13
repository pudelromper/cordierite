#!/usr/bin/bash
set -eo pipefail
if [[ -z ${project_root} ]]; then
    project_root=$(git rev-parse --show-toplevel)
fi
if [[ -z ${git_branch} ]]; then
    git_branch=$(git branch --show-current)
fi

# Get Inputs
target=$1
image=$2

# Set image/target/version based on inputs
# shellcheck disable=SC2154,SC1091
. "${project_root}/just_scripts/get-defaults.sh"

# Get info
container_mgr=$(just _container_mgr)
tag=$(just _tag "${image}")

if [[ ${image} =~ "gnome" ]]; then
    base_image="silverblue"
else
    base_image="kinoite"
fi

# Kernel flavour/version follow the CI matrix unless overridden
matrix_file="${project_root}/.github/workflows/build.yml"
kernel_flavor="${KERNEL_FLAVOR:-$(awk '/^ *kernel_flavor:/ {print $2; exit}' "${matrix_file}")}"
kernel_version="${KERNEL_VERSION:-$(awk '/^ *kernel_version:/ {print $2; exit}' "${matrix_file}")}"
if [[ ${target} == "cordierite-nvidia" && ! ${image} =~ "nvidia-open" ]]; then
    kernel_flavor="${KERNEL_FLAVOR_LTS:-$(awk '/- image: cordierite-nvidia$/ {f=1} f && /kernel_flavor:/ {print $2; exit}' "${matrix_file}")}"
    kernel_version="${KERNEL_VERSION_LTS:-$(awk '/- image: cordierite-nvidia$/ {f=1} f && /kernel_version:/ {print $2; exit}' "${matrix_file}")}"
    nvidia_flavor="nvidia-lts"
else
    nvidia_flavor="nvidia-open"
fi

# The nvidia stage is built on top of the cordierite (or cordierite-deck) stage
nvidia_base_ref="cordierite"
if [[ ${image} =~ "deck" ]]; then
    nvidia_base_ref="cordierite-deck"
fi

# Build Image
$container_mgr build -f Containerfile \
    --build-arg="IMAGE_NAME=${tag}" \
    --build-arg="IMAGE_VENDOR=${IMAGE_VENDOR:-localhost}" \
    --build-arg="IMAGE_BRANCH=${git_branch}" \
    --build-arg="BASE_IMAGE_NAME=${base_image}" \
    --build-arg="FEDORA_VERSION=${latest}" \
    --build-arg="KERNEL_FLAVOR=${kernel_flavor}" \
    --build-arg="KERNEL_VERSION=${kernel_version}" \
    --build-arg="NVIDIA_FLAVOR=${nvidia_flavor}" \
    --build-arg="NVIDIA_BASE=${nvidia_base_ref}" \
    --build-arg="SHA_HEAD_SHORT=$(git rev-parse --short HEAD)" \
    --build-arg="VERSION_TAG=${latest}-${git_branch}" \
    --build-arg="VERSION_PRETTY=${latest}-${git_branch} (local)" \
    ${GITHUB_TOKEN:+--secret "id=GITHUB_TOKEN,env=GITHUB_TOKEN"} \
    --target="${target}" \
    --tag localhost/"${tag}:${latest}-${git_branch}" \
    "${project_root}"
