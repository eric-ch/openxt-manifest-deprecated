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
    xenclient-dom0:xenclient-installer-image
    xenclient-dom0:xenclient-installer-part2-image
    xenclient-stubdomain:xenclient-stubdomain-initramfs-image
    xenclient-dom0:xenclient-dom0-image
    xenclient-uivm:xenclient-uivm-image
    xenclient-ndvm:xenclient-ndvm-image
    xenclient-syncvm:xenclient-syncvm-image
)

# Usage: certs [path]
# Create self-signed certificates in ./certs or create a link from [path] to
# ./certs to point to existing certificates.
# Expected existing PEM X.509 certificates are:
# - prod-cacert.pem
# - dev-cacert.pem
certs() {
    local path=$1

    if [ $# -eq 0 ]; then
        mkdir -p oxt-certs &&
        openssl genrsa -out oxt-certs/prod-cakey.pem 2048 &&
        openssl genrsa -out oxt-certs/dev-cakey.pem 2048 &&
        openssl req -new -x509 -key oxt-certs/prod-cakey.pem -out oxt-certs/prod-cacert.pem -days 1095 &&
        openssl req -new -x509 -key oxt-certs/dev-cakey.pem -out oxt-certs/dev-cacert.pem -days 1095 ||
            return 1
    else
        # Certificates are already setup for this tree.
        if [ -L "./oxt-certs" ]; then
            cat - >&2 <<EOF
Certificates are already linked to: `pwd`/oxt-certs.
If they are no longer required, remove the symlink to ./oxt-certs before running this script.
Aborting.
EOF
           return 1 
        fi
        # Certificates have already be generated in this tree.
        if [ -d "./oxt-certs" -a 
             -f "./oxt-certs/prod-cacert.pem" -o 
             -f "./oxt-certs/dev-cacert.pem" ]; then
            cat - >&2 <<EOF
Certificates already exist in: `pwd`/oxt-certs.
If they are no longer required, remove the ./oxt-certs directory before running this script.
Aborting.
EOF
            return 1
        fi
        # Point to the given certs.
        if [ -d "$path" -a 
             -f "$path/prod-cacert.pem" -o
             -f "$path/dev-cacert.pem" ]; then
            ln -sf "$path" ./oxt-certs
        else
            cat - >&2 <<EOF
Missing expected certificates in in \`$path'.
This script expects $path/{prod,dev}-cacert.pem X.509 certificates to be present.
Aborting.
EOF
            return 1
        fi
    fi
}


# Usage: build
# Build all the images of the OpenXT project using bitbake.
build() {
    for e in ${openxt_images[@]}; do
        local m="${e%%:*}"
        local i="${e##*:}"

        if ! MACHINE="$m" bitbake "$i" ; then
            echo "MACHINE="$m" bitbake \"$i\" failed." >&2
            break
        fi
    done
}

stage_build_output() {
    # TODO: Most of this could be taken from configuration with some efforts.
    local staging_path="./staging"
    local deploy_path="./deploy"
    local tclibc="glibc"
    local images_path="${deploy_path}/${tclibc}/images"

    local src="${images_path}/$1"
    local dst="${staging}/$2"

    if [ ! -e "${src}" -o "${src}" = ${images_path} ]; then
        echo "${src} is not ready yet." >&2
        return 1
    fi
    cp -ruv "${src}" "${dst}"
}

ship_iso() {
    # TODO: All this could be defined in a configuration file to make the glue
    # between the build-script and the bitbake build output easier to modify.

    local machine="xenclient-dom0"
    # TODO: Well this is ugly.
    local image_name="xenclient-installer-image-xenclient-dom0"

    # --- Stage installer initrd.
    local initrd_type="cpio.gz"
    local initrd_src_path="${machine}/${image_name}.${initrd_type}"
    local initrd_dst_name="rootfs.i686"
    local initrd_dst_path="iso/${initrd_dst_name}.${initrd_type}"

    stage_build_output "${initrd_src_path}" "${initrd_dst_path}"

    # --- Stage installer bulk files.
    local iso_src_path="${machine}/${image_name}/iso"

    stage_build_output "${iso_src_path}" "iso/iso"
    
    # --- Stage netboot directory.
    local netboot_src_path="${machine}/${image_name}/netboot"
    local netboot_dst_path="iso/netboot"

    stage_build_output "${netboot_src_path}" ""

    # --- Stage kernel.
    local kernel_type="bzImage"
    local kernel_src_path="${machine}/${kernel_type}.${image_name}.bin"
    local kernel_dst_path="iso/vmlinuz"

    stage_build_output "${kernel_src_path}" "${kernel_dst_path}"

    # --- Stage hypervisor.
    local hv_src_path="${machine}/xen.gz"
    local hv_dst_path="iso/xen.gz"
    
    stage_build_output "${hv_src_path}" "${hv_dst_path}"

    # --- Stage tboot.
    local tboot_src_path="${machine}/tboot.gz"
    local tboot_dst_path="iso/tboot.gz"

    stage_build_output "${tboot_src_path}" "${tboot_dst_path}"

    # --- Stage ACMs.
    local acms_src_path="${machine}/*.acm"
    local acms_dst_path="iso"

    stage_build_output "${acms_src_path}" "${acms_dst_path}"

    # --- Stage Licences.
    local lics_src_path="${machine}/license-*.txt"
    local lics_dst_path="iso"

    stage_build_output "${lics_src_path}" "${lics_dst_path}"

    # --- Stage microcode.
    local uc_src_path="${machine}/microcode_intel.bin"
    local uc_dst_path="iso"

    stage_build_output "${uc_src_path}" "${uc_dst_path}"
}

# Usage: deploy
# Deploy OpenXT on the selected installation media.
deploy() {
    echo "Not implemented yet."
    exit 0
}

# Sanitize input.
case "$1" in
    build)  build ;;
    deploy) deploy ;;
    certs)  shift 1
            certs $@ ;;
    *)      echo "Unknown command \`${cmd}'." >&2
            usage 1
            ;;
esac
