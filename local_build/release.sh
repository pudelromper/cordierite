#!/usr/bin/bash
# Scheduled entry point: optionally pull, build+push+sign images, then ISOs.

set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env

if [[ "${CORDIERITE_GIT_PULL:-0}" == "1" ]]; then
    log "updating ${PROJECT_ROOT} (${CORDIERITE_BRANCH})"
    git -C "${PROJECT_ROOT}" pull --ff-only
fi

"${LOCAL_BUILD_DIR}/build-images.sh" "$@"

if [[ "${CORDIERITE_BUILD_ISO:-0}" == "1" ]]; then
    "${LOCAL_BUILD_DIR}/build-iso.sh" "$@"
fi
