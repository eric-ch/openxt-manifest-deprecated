#! /bin/bash

# Default paths configuration.
conf_dir=${conf_dir:-./conf}
deploy_dir=${deploy_dir:-./deploy}
staging_dir=${staging_dir:-./staging}
tclibc=${tclibc:-glibc}
images_dir=${images_dir:-${deploy_dir}/${tclibc}/images}
repository_subdir=${repository_subdir:-repository/packages.main}
repository_dir=${repository_dir:-${staging_dir}/${repository_subdir}}
certs_dir=${certs_dir:-./oxt-certs}
host_syslinux_dir="${host_syslinux_dir:-/usr/lib/syslinux}"

# OpenXT configuration.
if [ -e "${conf_dir}/openxt.conf" ]; then
    . "${conf_dir}/openxt.conf"
fi
# Fallback naming configuration.
OPENXT_BUILD_ID=${OPENXT_BUILD_ID:-"0"}
OPENXT_VERSION=${OPENXT_VERSION:-"0.0.0"}
OPENXT_RELEASE=${OPENXT_RELEASE:-"none"}
OPENXT_UPGRADEABLE_RELEASES=${OPENXT_UPGRADEABLE_RELEASES:-"0.0.0"}

# Usage: usage <exit-code>
# Display the usage of this script.
usage() {
    echo "Usage: openxt [option] <command>"
    echo "Wrapper to build and deploy an OpenXT image."
    echo "  -h      display this help and exit."
    echo ""
    echo "Command list:"
    echo "  build:  Build all the images of the OpenXT project using bitbake."
    echo "  stage:  Create the staging layout from the build outputs. This is called by \`deploy' automatically."
    echo "  deploy: Deploy OpenXT installer on an installation media."
    echo "  sync:   Refresh OpenXT installer files on a given installation media."
    echo "  certs [path]:  Create self-signed certificates in \`${certs_dir}', or link \`${certs_dir}' to existing ones in [path]."
    echo ""
    exit $1
}

# Usage: certs [path]
# Create self-signed certificates in ./certs or create a link from [path] to
# ./certs to point to existing certificates.
# Expected existing PEM X.509 certificates are:
# - prod-cacert.pem
# - dev-cacert.pem
certs() {
    local path=$1

    if [ $# -eq 0 ]; then
        mkdir -p "${certs_dir}" &&
        openssl genrsa -out ${certs_dir}/prod-cakey.pem 2048 &&
        openssl genrsa -out ${certs_dir}/dev-cakey.pem 2048 &&
        openssl req -new -x509 -key ${certds_dir}/prod-cakey.pem -out ${certs_dir}/prod-cacert.pem -days 1095 &&
        openssl req -new -x509 -key ${certds_dir}/dev-cakey.pem -out ${certs_dir}/dev-cacert.pem -days 1095 ||
            return 1
    else
        # Certificates are already setup for this tree.
        if [ -L "${certs_dir}" ]; then
            cat - >&2 <<EOF
Certificates are already linked to: `pwd`/oxt-certs.
If they are no longer required, remove the symlink to ${certs_dir} before running this script.
Aborting.
EOF
           return 1
        fi
        # Certificates have already be generated in this tree.
        if [ -d "${certs_dir}" -a \
             -f "${certs_dir}/prod-cacert.pem" -o \
             -f "${certs_dir}/dev-cacert.pem" ]; then
            cat - >&2 <<EOF
Certificates already exist in: ${certs_dir}.
If they are no longer required, remove the ${certs_dir} directory before running this script.
Aborting.
EOF
            return 1
        fi
        # Point to the given certs.
        if [ -d "${path}" -a \
             -f "${path}/prod-cacert.pem" -o \
             -f "${path}/dev-cacert.pem" ]; then
            ln -sf "${path}" ${certs_dir}
        else
            cat - >&2 <<EOF
Missing expected certificates in in \`${path}'.
This script expects ${path}/{prod,dev}-cacert.pem X.509 certificates to be present.
Aborting.
EOF
            return 1
        fi
    fi
}


# Usage: build [mode]
# Build all the images of the OpenXT project using bitbake using the
# build-manifest file in conf_dir.
# modes:
#   clean: Run "cleanall" on the image recipe before building it.
build() {
    local mode=$1

    # Overwrite the build timestamp.
    echo "OPENXT_BUILD_DATE=\"$(date '+%T %D')\"" > ${conf_dir}/openxt-build-date.conf
    while read l ; do
        if [ -z "${l%%#*}" ]; then
            continue
        fi

        local entry=(${l})
        local machine="${entry[0]}"
        local image="${entry[1]}"

        if [ "${mode}" = "clean" ]; then
            MACHINE="${machine}" bitbake -c cleanall "${image}"
        fi
        if ! MACHINE="${machine}" bitbake "${image}" ; then
            echo "MACHINE="${machine}" bitbake \"${image}\" failed." >&2
            break
        fi

    done < "${conf_dir}/build-manifest"
}

# Usage: stage_build_output source destination
# Copy a build output from its deployed location (images_dir) to the staging
# directory (staging_dir)
stage_build_output() {
    local src="${images_dir}/$1"
    local dst="${staging_dir}/$2"

    if [ $# -ne 2 -a ! -e "${src}" ]; then
        echo "${src} is not ready yet." >&2
        return 1
    fi
    mkdir -p `dirname ${dst}`
    echo "cp -ruv -L -T ${src} ${dst}"
    cp -ruv -L -T "${src}" "${dst}"
}

# Usage: stage_build_output_by_suffix source suffix destination
# Copy a set of build output matching *suffix from their deployed location
# (images_dir) to the staging directory (staging_dir).
stage_build_output_by_suffix() {
    local dst="${staging_dir}/$3"

    mkdir -p `dirname ${dst}`

    for f in "${images_dir}/${1}"*"${2}"; do
        if [ ! -e "${f}" ]; then
            echo "${f} is not ready yet." >&2
            break
        fi
        cp -ruv -L "${f}" "${dst}/`basename ${f}`"
    done
}

sign_repository() {
    if [ ! -f "${repository_dir}/XC-PACKAGES" ]; then
        echo "Repository in \`${repository_dir}' is not ready yet, XC-PACKAGES is missing." >&2
        return 1
    fi

    local xc_package_sha256=($(sha256sum "${repository_dir}/XC-PACKAGES"))
    # This file seems to be used, amongst other things, for signing the "repository".
    # Due to the signing process, it needs to have a fixed size, and somehow
    # 1MB is that size...
    # TODO: Discombobulate that...
    set +o pipefail
    {
        cat <<EOF
xc:main
pack:Base Pack
build:${OPENXT_BUILD_ID}
version:${OPENXT_VERSION}
release:${OPENXT_RELEASE}
upgrade-from:${OPENXT_UPGRADEABLE_RELEASES}
packages:${xc_package_sha256}
EOF
    } | head -c $((1024 * 1024)) > "${repository_dir}/XC-REPOSITORY"
    set -o pipefail

    openssl smime -sign \
        -aes256 \
        -binary \
        -in "${repository_dir}/XC-REPOSITORY" \
        -out "${repository_dir}/XC-SIGNATURE" \
        -outform PEM \
        -signer "${certs_dir}/dev-cacert.pem" \
        -inkey "${certs_dir}/dev-cakey.pem"
}

# Usage: stage_repository_entry machine image-identifier source-image-name destination-image-name image-mount-point
# Copy an bitbake assembled image, for a given machine, from the deployment
# directory (deploy_dir) to the repository staging location (repository_dir),
# then fill the metadata in the repository XC-PACKAGES files.
stage_repository_entry() {
    local machine="$1"
    local id="$2"
    local src="$3"
    local dst="$4"
    local mnt="$5"

    if ! stage_build_output "${machine}/${src}" "${repository_subdir}/${dst}" ; then
        return 1
    fi

    local size=($(du -b "${repository_dir}/${dst}"))
    local sha256=($(sha256sum "${repository_dir}/${dst}"))
    local format=""
    case "${dst}" in
        *.tar.bz2) format="tarbz2";;
        *.ext3.gz) format="ext3gz";;
        *.vhd.gz) format="vhdgz";;
        *)
            echo "Unknown format for image ${dst}."
            return 1
            ;;
    esac

    if [ -f "${repository_dir}/XC-PACKAGES" ] && grep -q "^${id} " "${repository_dir}/XC-PACKAGES" ; then
        sed -i -e "s#^${id}.\+#${id} ${size} ${sha256} ${format} required ${dst} ${mnt}#" "${repository_dir}/XC-PACKAGES"
    else
        echo "${id} ${size} ${sha256} ${format} required ${dst} ${mnt}" >> "${repository_dir}/XC-PACKAGES"
    fi
}

# Usage: stage_repository
# Copy images from the deployment directory (deploy_dir) to the repository
# staging area (repository_dir) then use the generated metadata to sign the
# repository.
# Uses the images-manifest file in conf_dir to prepare the images.
stage_repository() {
    while read l; do
        # Quick parsing/formating.
        if [ -z "${l%%#*}" ]; then
            continue
        fi
        entry=(${l})
        machine="${entry[0]}"
        img_id="${entry[1]}"
        img_src_label="${entry[2]}"
        img_type="${entry[3]}"
        img_dst_label="${entry[4]}"
        img_dst_mnt="${entry[5]}"

        img_src_name="${img_src_label}-${machine}.${img_type}"
        img_dst_name="${img_dst_label}.${img_type}"

        stage_repository_entry "${machine}" "${img_id}" "${img_src_name}" "${img_dst_name}" "${img_dst_mnt}"
    done < ${conf_dir}/images-manifest

    sign_repository
}

# Usage: stage_iso <machine>
# Copy images from the deployment directory (deploy_dir) of the installer
# machine to the iso staging area (staging_dir) that are specific to ISO image
# generation.
stage_iso() {
    local machine="$1"
    local isolinux_subdir="iso/isolinux"
    # TODO: Well this is ugly.
    local image_name="xenclient-installer-image-${machine}"

    # --- Stage installer bulk files.
    local iso_src_path="${machine}/${image_name}/iso"

    stage_build_output "${iso_src_path}" "${isolinux_subdir}"
    # --- Ammend isolinux configuration for that image.
    # Changing the staging is fine as it will be overwritten for every
    # "stage_iso" command.
    sed -i -e "s#[$]OPENXT_VERSION#${OPENXT_VERSION}#g" "${staging_dir}/${isolinux_subdir}/bootmsg.txt"
    sed -i -e "s#[$]OPENXT_BUILD_ID#${OPENXT_BUILD_ID}#g" "${staging_dir}/${isolinux_subdir}/bootmsg.txt"

    # --- Stage installer initrd.
    local initrd_type="cpio.gz"
    local initrd_src_path="${machine}/${image_name}.${initrd_type}"
    local initrd_dst_name="rootfs.gz"
    local initrd_dst_path="${isolinux_subdir}/${initrd_dst_name}"

    stage_build_output "${initrd_src_path}" "${initrd_dst_path}"

    # --- Stage netboot directory.
    local netboot_src_path="${machine}/${image_name}/netboot"
    local netboot_dst_path="${isolinux_subdir}/netboot"

    stage_build_output "${netboot_src_path}" "${netboot_dst_path}"

    # --- Stage kernel.
    local kernel_type="bzImage"
    local kernel_src_path="${machine}/${kernel_type}-${machine}.bin"
    local kernel_dst_path="${isolinux_subdir}/vmlinuz"

    stage_build_output "${kernel_src_path}" "${kernel_dst_path}"

    # --- Stage hypervisor.
    local hv_src_path="${machine}/xen.gz"
    local hv_dst_path="${isolinux_subdir}/xen.gz"

    stage_build_output "${hv_src_path}" "${hv_dst_path}"

    # --- Stage tboot.
    local tboot_src_path="${machine}/tboot.gz"
    local tboot_dst_path="${isolinux_subdir}/tboot.gz"

    stage_build_output "${tboot_src_path}" "${tboot_dst_path}"

    # --- Stage ACMs & license.
    local acms_src_dir="${machine}/"
    local acms_src_suffix=".acm"
    local acms_dst_path="${isolinux_subdir}"

    stage_build_output_by_suffix "${acms_src_dir}" "${acms_src_suffix}" "${acms_dst_path}"

    local lic_src_path="${machine}/license-SINIT-ACMs.txt"
    local lic_dst_path="${isolinux_subdir}/license-SINIT-ACMs.txt"

    stage_build_output "${lic_src_path}" "${lic_dst_path}"

    # --- Stage microcode.
    local uc_src_path="${machine}/microcode_intel.bin"
    local uc_dst_path="${isolinux_subdir}/microcode_intel.bin"

    stage_build_output "${uc_src_path}" "${uc_dst_path}"

    # --- Create the EFI boot partition in the staging area.

    local efi_img="${staging_dir}/${isolinux_subdir}/efiboot.img"
    local efi_path=$(mktemp -d)

    rm -f ${efi_img}
    mkdir -p "$(dirname "${efi_img}")"
    dd if=/dev/zero bs=1M count=5 of="${efi_img}"
    /sbin/mkfs -t fat "${efi_img}"
    mmd -i ${efi_img} EFI
    mmd -i ${efi_img} EFI/BOOT
    mcopy -i "${efi_img}" "${images_dir}/${machine}/grubx64.efi" ::EFI/BOOT/BOOTX64.EFI

    # --- Stage hybrid MBR image.
    local isohdp_src="${machine}/isohdpfx.bin"
    local isohdp_dst="${isolinux_subdir}/isohdpfx.bin"

    # Only post stable-8 with UEFI & xorriso.
    if [ -e "${images_dir}/${isohdp_src}" ]; then
        stage_build_output "${isohdp_src}" "${isohdp_dst}"
    fi
}

# Usage: stage_pxe <machine>
# Copy images from the deployment directory (deploy_dir) of the installer
# machine to the pxe staging area (staging_dir).
stage_pxe() {
    local machine="$1"
    local pxe_subdir="pxe"
    # TODO: Well this is ugly.
    local image_name="xenclient-installer-image-${machine}"

    # --- Stage installer bulk files.
    local pxe_src_path="${machine}/${image_name}/netboot/"
    local pxe_src_suffix=".ans"
    stage_build_output_by_suffix "${pxe_src_path}" "${pxe_src_suffix}" "${pxe_subdir}"

    # --- Stage installer initrd.
    local initrd_type="cpio.gz"
    local initrd_src_path="${machine}/${image_name}.${initrd_type}"
    local initrd_dst_name="rootfs.gz"
    local initrd_dst_path="${pxe_subdir}/${initrd_dst_name}"

    stage_build_output "${initrd_src_path}" "${initrd_dst_path}"

    # --- Stage kernel.
    local kernel_type="bzImage"
    local kernel_src_path="${machine}/${kernel_type}-${machine}.bin"
    local kernel_dst_path="${pxe_subdir}/vmlinuz"

    stage_build_output "${kernel_src_path}" "${kernel_dst_path}"

    # --- Stage hypervisor.
    local hv_src_path="${machine}/xen.gz"
    local hv_dst_path="${pxe_subdir}/xen.gz"

    stage_build_output "${hv_src_path}" "${hv_dst_path}"

    # --- Stage tboot.
    local tboot_src_path="${machine}/tboot.gz"
    local tboot_dst_path="${pxe_subdir}/tboot.gz"

    stage_build_output "${tboot_src_path}" "${tboot_dst_path}"

    # --- Stage ACMs & license.
    local acms_src_dir="${machine}/"
    local acms_src_suffix=".acm"
    local acms_dst_path="${pxe_subdir}"

    stage_build_output_by_suffix "${acms_src_dir}" "${acms_src_suffix}" "${acms_dst_path}"

    local lic_src_path="${machine}/license-SINIT-ACMs.txt"
    local lic_dst_path="${pxe_subdir}/license-SINIT-ACMs.txt"

    stage_build_output "${lic_src_path}" "${lic_dst_path}"

    # --- Stage microcode.
    local uc_src_path="${machine}/microcode_intel.bin"
    local uc_dst_path="${pxe_subdir}/microcode_intel.bin"

    stage_build_output "${uc_src_path}" "${uc_dst_path}"
}

# Usage: check_cmd_version
# Compares stage/deploy command against OpenXT version and abort if support is
# no longer provided.
check_cmd_version() {
    local cmd="$1"

    # Ignore development/hacked versions.
    if [ "${OPENXT_VERSION}" = "0.0.0" -o -z "${OPENXT_VERSION}" ]; then
        return 0
    fi
    if [ "${OPENXT_VERSION%%.*}" -ge "8" ]; then
        case "${cmd}" in
            *"-old")
                echo "\`${cmd}' is no longer supported with OpenXT 8 and later versions. See \`${cmd%%-old}' command replacement." >&2
                exit 1 ;;
            *) return 0 ;;
        esac
    else
        case "${cmd}" in
            *"-old") return 0 ;;
            "*") echo "\`${cmd}' is not supported with OpenXT 7 and earlier versions. See \`${cmd}-old' legacy support." >&2
               exit 1 ;;
        esac
    fi
}

# Usage: stage_usage
# Display usage for this command wrapper.
stage_usage() {
    echo "Stagging command list:"
    echo "  iso-old: Copy BIOS/ISO installer related build results, from Bitbake deployment directory to the staging area."
    echo "  iso: Copy EFI/ISO installer related build results, from Bitbake deployment directory to the staging area."
    echo "  pxe-old: Copy PXE files for the installer from Bitbake deployment directory to the staging area."
    echo "  pxe: Copy PXE files for the installer from Bitbake deployment directory to the staging area."
    echo "  repository: Copy build results from Bitbake deployment directory to the staging area and update the relevant meta-data."
    exit $1
}

# Usage: stage <command>
# Stage commands wrapper.
stage() {
    target="$1"
    shift 1
    case "${target}" in
        "iso-old") check_cmd_version "${target}"
                   stage_iso xenclient-dom0 ;;
        "iso") check_cmd_version "${target}"
               stage_iso openxt-installer ;;
        "pxe-old") check_cmd_version "${target}"
                   stage_pxe xenclient-dom0 ;;
        "pxe") check_cmd_version "${target}"
               stage_pxe openxt-installer ;;
        "repository") stage_repository ;;
        "help") stage_usage 0 ;;
        *)  echo "Unknown staging command \`${target}'." >&2
            stage_usage 1
            ;;
    esac
}


# Usage: deploy_iso_legacy
# Run the required staging steps and generate the ISO image.
deploy_iso_legacy() {
    # TODO: This could be defined from configuration.
    local iso_name="openxt-installer.iso"
    local iso_path="${deploy_dir}/${iso_name}"

    # Prepare repository layout and write XC-{PACKAGE,REPOSITORY,SIGNATURE}
    # meta files.
    stage "repository"
    # Prepare ISO image layout.
    # TODO: Amend syslinux files to reflect versions & such
    stage "iso-old"

    genisoimage -o "${iso_path}" \
        -b "isolinux/isolinux.bin" -c "isolinux/boot.cat" \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -r -J -l -V "OpenXT ${OPENXT_VERSION} installer." \
        "${staging_dir}/iso" \
        "${staging_dir}/repository"
    if [ $? -ne 0 ]; then
        echo "genisoimage failed."
        return 1
    fi

    ${staging_dir}/iso/isolinux/isohybrid ${iso_path}
    if [ $? -ne 0 ]; then
        echo "isohybrid failed."
        return 1
    fi
}

# Usage: deploy_iso
# Run the required staging steps and generate the ISO image.
deploy_iso() {
    # TODO: This could be defined from configuration.
    local iso_name="openxt-installer.iso"
    local iso_path="${deploy_dir}/${iso_name}"

    # Prepare repository layout and write XC-{PACKAGE,REPOSITORY,SIGNATURE}
    # meta files.
    stage "repository"
    # Prepare ISO image layout.
    # TODO: Amend syslinux files to reflect versions & such
    stage "iso"

    xorriso -as mkisofs \
        -o "${iso_path}" \
        -isohybrid-mbr "${staging_dir}/iso/isolinux/isohdpfx.bin" \
        -c "isolinux/boot.cat" \
        -b "isolinux/isolinux.bin" \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -eltorito-alt-boot \
        -e "isolinux/efiboot.img" \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -r \
        -J \
        -l \
        -V "OpenXT ${OPENXT_VERSION} installer." \
        -f \
        -quiet \
        "${staging_dir}/iso" \
        "${staging_dir}/repository"
}

deploy_pxe_usage() {
    local rc="$1"
    echo "Usage: ./openxt.sh deploy pxe [-r [<repo-user>@]<repo-server>:<repo-path>] [<tftp-user>@]<tftp-server>:<tftp-path> <repository-uri>"
    echo "  -r  rsync repository files to http(s) server passed as argument, [<repo-user>@]<repo-server>:<repo-path>."
    exit "${rc}"
}

__deploy_pxe() {
    local pxe_staging="${staging_dir}/pxe"
    local repo_dst=""

    # Prepare repository layout and write XC-{PACKAGE,REPOSITORY,SIGNATURE}
    # meta files.
    stage "repository"

    while getopts "hr:" opt; do
        case "${opt}" in
            h) deploy_pxe_usage 0 ;;
            :) echo "Option \`${OPTARG}' is missing an argument." >&2
               deploy_pxe_usage 1 ;;
            \?) echo "Unknown option \`${OPTARG}'." >&2
                deploy_pxe_usage 1 ;;
            r) repo_dst="${OPTARG}" ;;
        esac
    done
    shift $((${OPTIND} - 1))

    if [ "$#" -ne 2 ]; then
        deploy_pxe_usage 1
    fi

    local tftp_dst="$1"
    local repo_url="$2"

    # TODO: Not great, will change staging data...
    #       Not too bad since we "stage pxe" again every time.
    local answer_files=()
    for ans in "${pxe_staging}"/*.ans; do
        sed -i "s|@NETBOOT_URL@|${repo_url}|" "${ans}"
        answer_files+=("${ans}")
    done
    rsync -avzr "${pxe_staging}/" "${tftp_dst}"
    if [ -n "${repo_dst}" ]; then
        echo rsync -avzr "${staging_dir}/repository/" ${answer_files[@]} "${repo_dst}"
        rsync -avzr "${staging_dir}/repository/" ${answer_files[@]} "${repo_dst}"
    fi
}
deploy_pxe_legacy() {
    # Prepare PXE staging.
    stage "pxe-old"

    __deploy_pxe $@
}
deploy_pxe() {
    # Prepare PXE staging.
    stage "pxe"

    __deploy_pxe $@
}

# Usage: deploy_usage
# Display usage for this command wrapper.
deploy_usage() {
    echo "Deployment command list:"
    echo "  iso-old: Create a BIOS/MBR bootable ISO hybrid image of an OpenXT installer (can be dd'ed on a thumbdrive). This installeris available until OpenXT 7."
    echo "  iso: Create an EFI bootable ISO hybrid image of an OpenXT installer (can be dd'ed on a thumbdrive). This installer is available starting with OpenXT 8."
    echo "  pxe-old: Copy a PXE compatible OpenXT installer to the given [<tftp-user>@]<tftp-server>:<tftp-path> tftp server, and setup the installer to fetch repository from <repo-uri>."
    echo "  pxe: Copy a PXE compatible OpenXT installer to the given [<tftp-user>@]<tftp-server>:<tftp-path> tftp server, and setup the installer to fetch repository from <repo-uri>."
    exit $1
}

# Usage: deploy <command>
# Deploy OpenXT on the selected installation media.
deploy() {
    target="$1"
    shift 1

    case "${target}" in
        "iso-old") check_cmd_version "${target}"
                   deploy_iso_legacy $@ ;;
        "iso") check_cmd_version "${target}"
               deploy_iso $@ ;;
        "pxe-old") deploy_pxe_legacy $@ ;;
        "pxe") deploy_pxe $@ ;;
        "help") deploy_usage 0 ;;
        *) echo "Unknown staging command \`${target}'." >&2
           deploy_usage 1
           ;;
    esac
}


# Usage: sync <command> [args]
# Synchronize install media with what is new in the staging.
sync() {
    target=$1
    shift 1
    case "${target}" in
        *) echo "Unknown sync command \`${target}'." >&2
           return 1
           ;;
    esac
}


# Parse options.
while getopts ":h" opt; do
    case $opt in
        h)  usage 0 ;;
        :)  echo "Option \`${OPTARG}' is missing an argument." >&2
            usage 1
            ;;
        \?) echo "Unknown option \`${OPTARG}'." >&2
            usage 1
            ;;
    esac
done
shift $((${OPTIND} - 1))

if [ $# -lt 1 ]; then
    echo "No command specified." >&2
    usage 1
fi
# Sanitize input.
command="$1"
shift 1
case "${command}" in
    "build")  build ;;
    "rebuild") rebuild ;;
    "deploy") deploy $@ ;;
    "stage") stage $@ ;;
    "certs") certs $@ ;;
    "sync") sync $@ ;;
    "help") usage 0 ;;
    *) echo "Unknown command \`${command}'." >&2
       usage 1
       ;;
esac
