#! /bin/sh

__DEFAULT_BITBAKE_PATH="`pwd`/bitbake"
BITBAKE_PATH=${BITBAKE_PATH:-${__DEFAULT_BITBAKE_PATH}}

[ ! -e `which python` ] && {
    echo "python is missing." >&2
    exit 1
}

SQLITE3_VERSION=`python -c "import sqlite3; print(sqlite3.sqlite_version)"`
SQLITE3_VMAJOR=${SQLITE3_VERSION%%.*}
__SQLITE3_VMINOR=${SQLITE3_VERSION#*.}
SQLITE3_VMINOR=${__SQLITE3_VMINOR%.*}

# This quirks was not required on a Debian jessie i386 environment that deploys
# sqlite 3.8.7. So lets assume it is a `regression' introduced later, or
# something must be done differently in later version, but bitbake does not yet
# account for it.
pushd ${BITBAKE_PATH} > /dev/null
    ln -sf ../.repo/manifests/patches/bitbake patches
    echo "SQLite3 version: ${SQLITE3_VERSION}."
    if [ \( ${SQLITE3_VMAJOR} -lt 3 \) -o \
         \( ${SQLITE3_VMAJOR} -eq 3 -a ${SQLITE3_VMINOR} -gt 8 \) ]; then
        quilt push -a || echo "Failed to apply bitbake patch-queue." >2
    fi
popd > /dev/null
