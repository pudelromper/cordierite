#!/usr/bin/bash
# Fetch ublue-os/bazzite main and merge it into the current branch.
# Replaces the pull bot. Conflicts are left in the tree for you to resolve;
# the files that usually conflict are listed at the end.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/ublue-os/bazzite.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"

if ! git remote get-url upstream >/dev/null 2>&1; then
    git remote add upstream "${UPSTREAM_URL}"
fi
git fetch upstream "${UPSTREAM_BRANCH}" --no-tags

behind="$(git rev-list --count "HEAD..upstream/${UPSTREAM_BRANCH}")"
if [[ "${behind}" == "0" ]]; then
    echo "Already up to date with upstream/${UPSTREAM_BRANCH}."
    exit 0
fi
echo "Merging ${behind} upstream commits into $(git branch --show-current)..."

if git merge --no-ff --no-edit "upstream/${UPSTREAM_BRANCH}"; then
    echo "Merged cleanly. Review the result and run 'just just-check' before pushing."
    exit 0
fi

echo
echo "Merge has conflicts. Resolve them, then 'git add' and 'git commit'."
echo "Conflicted files:"
git diff --name-only --diff-filter=U | sed 's/^/  /'
echo
echo "Cordierite-specific intent lives in: Containerfile, .github/workflows/build*.yml,"
echo "build_files/{image-info,configure-kde}, installer/, system_files/desktop/shared/usr/share/yafti/yafti.yml,"
echo "the MOTD templates and spec_files/steamdeck-kde-presets."
exit 1
