#! /bin/bash

# Usage: usage <exit-code>
# Display the usage of this script.
usage() {
    echo "Usage: openxt [option] <command>"
    echo "Wrapper to build and deploy an OpenXT image."
    echo "  -h      display this help and exit."
    echo ""
    echo "Command list:"
    echo "  build:  Build all the images of the OpenXT project using bitbake."
    echo "  deploy: Deploy OpenXT installer on the installation media."
    echo ""
    exit $1
}

# Parse options.
while getopts ":h" opt; do
    case $opt in
        h)  usage 0 ;;
        :)  echo "Options \`${OPTARG}' is missing an argument." >&2
            usage 1
            ;;
        \?) echo "Unknown option \`${OPTARG}'." >&2
            usage 1
            ;;
    esac
done
shift $((${OPTIND} - 1))

# List of MACHINE:image-recipe name for OpenXT
openxt_images=(
    xenclient-dom0:xenclient-initramfs-image
    xenclient-dom0:xenclient-dom0-image
    xenclient-dom0:xenclient-installer-image
    xenclient-dom0:xenclient-installer-part2-image
    xenclient-stubdomain:xenclient-stubdomain-initramfs-image
    xenclient-uivm:xenclient-uivm-image
    xenclient-ndvm:xenclient-ndvm-image
    xenclient-syncvm:xenclient-syncvm-image
)

# Usage: build
# Build all the images of the OpenXT project using bitbake.
build() {
    for e in ${openxt_images[@]}; do
        local m="${e%%:*}"
        local i="${e##*:}"

        MACHINE="$m" bitbake "$i" || break
    done
}

# Usage: deploy
# Deploy OpenXT on the selected installation media.
deploy() {
    echo "Not implemented yet."
    exit 0
}

# Sanitize input.
for cmd in $@; do
    case "$cmd" in
        build)  build ;;
        deploy) deploy;;
        *)      echo "Unknown command \`${cmd}'." >&2
                usage 1
                ;;
    esac
done
