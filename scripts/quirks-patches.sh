#! /bin/bash

# Sanity check.
if [ ! -e `which git` ]; then
    echo "git is missing." >&2
    exit 1
fi

# Path to look for patches.
# Default is ./script/quirks-patches.sh from the build tree root.
__DEFAULT_PATCHES="`pwd`/.repo/manifests/patches"
PATCHES_PATH=${PATCHES_PATH:-${__DEFAULT_PATCHES}}

# ./layers/openembedded-core.
__DEFAULT_OECORE_PATH="`pwd`/layers/openembedded-core"
OECORE_PATH=${OECORE_PATH:-${__DEFAULT_OECORE_PATH}}

# ./bitbake.
__DEFAULT_BITBAKE_PATH="`pwd`/bitbake"
BITBAKE_PATH=${BITBAKE_PATH:-${__DEFAULT_BITBAKE_PATH}}

# Array with:
#   <patch-queue subdirectory>:<repository>
patchqueues=(
    ${PATCHES_PATH}/openembedded-core:${OECORE_PATH}
    ${PATCHES_PATH}/bitbake:${BITBAKE_PATH}
)

for pq in ${patchqueues[@]}; do
    src="${pq##*:}"
    dst="${pq%%:*}"

    ln -sf -r "${dst}" "${src}/patches"
    pushd "${src}" >/dev/null
    quilt push -a >/dev/null 2>&1
    if [ $? -eq 1 ]; then
        echo "Failed to apply patch-queue in \`${src}'." >&2
        exit 1
    fi
done
