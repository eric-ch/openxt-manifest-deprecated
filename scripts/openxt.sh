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
        cp -ruv -L "${f}" "${dst}"
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
    if [ -e "${isohdp_src}" ]; then
        stage_build_output "${isohdp_src}" "${isohdp_dst}"
    fi
}

# Usage: stage_usb <machine>
# Copy images from the deployment directory (deploy_dir) of the installer
# machine to the usb staging area (staging_dir) that are specific to USB image
# generation.
stage_usb() {
    local machine="$1"
    local syslinux_subdir="usb/syslinux"
    # TODO: Well this is ugly.
    local image_name="xenclient-installer-image-${machine}"

    # --- Write syslinux configuration.
    mkdir -p "${staging_dir}/${syslinux_subdir}"
    cat - > "${staging_dir}/${syslinux_subdir}/syslinux.cfg" <<EOF
SERIAL 0
DEFAULT openxt
DISPLAY bootmsg.txt
PROMPT 1
TIMEOUT 20
LABEL openxt
  kernel mboot.c32
  append tboot.gz min_ram=0x2000000 loglvl=all serial=115200,8n1,0x3f8 logging=serial,memory --- xen.gz flask=disabled console=com1 dom0_max_vcpus=1 com1=115200,8n1,pci dom0_mem=max:8G ucode=-1 --- vmlinuz quiet root=/dev/ram rw start_install=new eject_cdrom=1 answerfile=/install/answers/default.ans console=hvc0 console=/dev/tty2 selinux=0 --- rootfs.gz --- gm45.acm --- q35.acm --- q45q43.acm --- duali.acm --- quadi.acm --- ivb_snb.acm --- xeon56.acm --- xeone7.acm --- hsw.acm --- bdw.acm --- skl.acm --- kbl.acm --- microcode_intel.bin
EOF
    cat - > "${staging_dir}/${syslinux_subdir}/bootmsg.txt" << EOF

OpenXT $OPENXT_VERSION (Build $OPENXT_BUILD_ID)

EOF
    # --- Stage installer initrd.
    local initrd_type="cpio.gz"
    local initrd_src_path="${machine}/${image_name}.${initrd_type}"
    local initrd_dst_name="rootfs.gz"
    local initrd_dst_path="${syslinux_subdir}/${initrd_dst_name}"

    stage_build_output "${initrd_src_path}" "${initrd_dst_path}"

    # --- Stage kernel.
    local kernel_type="bzImage"
    local kernel_src_path="${machine}/${kernel_type}-${machine}.bin"
    local kernel_dst_path="${syslinux_subdir}/vmlinuz"

    stage_build_output "${kernel_src_path}" "${kernel_dst_path}"

    # --- Stage hypervisor.
    local hv_src_path="${machine}/xen.gz"
    local hv_dst_path="${syslinux_subdir}/xen.gz"

    stage_build_output "${hv_src_path}" "${hv_dst_path}"

    # --- Stage tboot.
    local tboot_src_path="${machine}/tboot.gz"
    local tboot_dst_path="${syslinux_subdir}/tboot.gz"

    stage_build_output "${tboot_src_path}" "${tboot_dst_path}"

    # --- Stage ACMs & license.
    local acms_src_dir="${machine}/"
    local acms_src_suffix=".acm"
    local acms_dst_path="${syslinux_subdir}"

    stage_build_output_by_suffix "${acms_src_dir}" "${acms_src_suffix}" "${acms_dst_path}"

    local lic_src_path="${machine}/license-SINIT-ACMs.txt"
    local lic_dst_path="${syslinux_subdir}/license-SINIT-ACMs.txt"

    stage_build_output "${lic_src_path}" "${lic_dst_path}"

    # --- Stage microcode.
    local uc_src_path="${machine}/microcode_intel.bin"
    local uc_dst_path="${syslinux_subdir}/microcode_intel.bin"

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
            "iso-old"|"usb-old")
                echo "\`${cmd}' is no longer supported with OpenXT 8 and later versions. See \`${cmd%%-old}' command replacement." >&2
                exit 1 ;;
            "iso"|"usb") return 0 ;;
        esac
    else
        case "${cmd}" in
            "iso-old"|"usb-old") return 0 ;;
            "iso"|"usb") echo "\`${cmd}' is not supported with OpenXT 7 and earlier versions. See \`${cmd}-old' legacy support." >&2
               exit 1 ;;
        esac
    fi
}

# Usage: stage_usage
# Display usage for this command wrapper.
stage_usage() {
    echo "Stagging command list:"
    echo "  usb-old: Copy BIOS/USB installer related build results, from Bitbake deployment directory to the staging area."
    echo "  iso-old: Copy BIOS/ISO installer related build results, from Bitbake deployment directory to the staging area."
    echo "  usb: Copy EFI/USB installer related build results, from Bitbake deployment directory to the staging area."
    echo "  iso: Copy EFI/ISO installer related build results, from Bitbake deployment directory to the staging area."
    echo "  repository: Copy build results from Bitbake deployment directory to the staging area and update the relevant meta-data."
    exit $1
}

# Usage: stage <command>
# Stage commands wrapper.
stage() {
    target="$1"
    shift 1
    case "${target}" in
        "usb-old") check_cmd_version "${target}"
                   stage_usb xenclient-dom0 ;;
        "iso-old") check_cmd_version "${target}"
                   stage_iso xenclient-dom0 ;;
        "usb") check_cmd_version "${target}"
               stage_usb openxt-installer ;;
        "iso") check_cmd_version "${target}"
               stage_iso openxt-installer ;;
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

# Usage: __prepare_installer_legacy </dev/sdX>
# Need UID 0.
# Erase, format and prepare /dev/sdX with OpenXT MBR legacy installer:
#  - Create /dev/sdX1, FAT32 bootable partition;
#  - Install Syslinux in /dev/sdX1;
#  - Dump Syslinux MBR on /dev/sdX;
#  - Install OpenXT installer in /dev/sdX1;
#  - Install OpenXT installation repository in the repository sub-directory;
__prepare_installer_legacy() {
    local device="$1"
    local partition="${device}1"
    local mnt=`mktemp -d`

    # Sanity.
    if [ "$#" -ne "1" ]; then
        echo "__prepare_installer_legacy() has no device specified." >&2
        return 1
    fi
    if [ "${UID}" -ne "0" ]; then
        echo "__prepare_installer_legacy() has to be run as root." >&2
        return 1
    fi

    set -e
    # Wipe it all. YOU WERE WARNED.
    dd bs=512 count=63 if=/dev/zero of="${device}"

    # Partition.
    parted --script "${device}" \
        mklabel msdos \
        mkpart primary fat32 1MiB 100% \
        set 1 boot on

    # Format media.
    mkfs -t fat "${partition}"

    # Prepare media layout.
    mount "${partition}" "${mnt}"
    mkdir -p "${mnt}/syslinux"
    umount "${partition}"
    # Install syslinux.
    syslinux -i "${partition}" -d "syslinux"
    # ... with MBR.
    dd conv=notrunc bs=440 count=1 if="${host_syslinux_dir}/bios/mbr.bin" of="${device}"

    # Deploy syslinux modules.
    mount "${partition}" "${mnt}"
    for bin in mboot.c32 ldlinux.c32 libcom32.c32 ; do
        cp -v "${host_syslinux_dir}/bios/${bin}" "${mnt}/syslinux"
    done

    # Deploy installation files.
    cp -rv "${staging_dir}/usb/syslinux" "${mnt}/"
    cp -rv "${staging_dir}/repository/packages.main" "${mnt}/"

    umount "${mnt}"
    rm -r "${mnt}"
    set +e
}

# Usage: deploy_usb_legacy </dev/sdX>
# Run the required staging steps, format /dev/sdX, install the Syslinux MBR on
# it and OpenXT installer and repository on it.
deploy_usb_legacy() {
    local sd="$1"
    local reply=""
    local attempts=5

    # Sanity.
    if [ "$#" -lt 1 ]; then
        echo "No device provided." >&2
        return 1
    fi
    if [ ! -b "${sd}" ]; then
        echo "\`${sd}' is not a block device." >&2
        return 1
    fi

    # Safeguard.
    local usb_driver="$(udevadm info --query=all -n ${sd} | sed -ne 's/E: ID_USB_DRIVER=\(.\+\)/\1/p')"

    if [ "${usb_driver}" != "usb-storage" ]; then
        echo "${sd} is not a storage USB device. Abort." >&2
        return 1
    fi

    # Last warning...
    echo -n "This will erase ${sd}, are you sure? (y/N) "
    while [ "${reply}" != "y" ]; do
        read reply
        case "${reply}" in
            ""|"n"|"N") return 0 ;;
        esac
        if [ "${attempts}" -lt 0 ]; then
            echo "" >&2
            echo "Assuming \`no'... Bailing out." >&2
            return 1
        fi
    done

    # Prepare repository layout and write XC-{PACKAGE,REPOSITORY,SIGNATURE}
    # meta files.
    stage "repository"
    # Prepare USB image layout.
    stage "usb-old"
    # Deploy.
    sudo su -c " \
        staging_dir=${staging_dir}; \
        host_syslinux_dir=${host_syslinux_dir}; \
        $(declare -f __prepare_installer_legacy); \
        __prepare_installer_legacy ${sd} \
    "
}

# Usage: __prepare_installer </dev/sdX>
# Need UID 0.
# Erase, format and prepare /dev/sdX with OpenXT EFI installer:
#  - Create /dev/sdX1, ESP bootable FAT32 partition;
#  - Create /dev/sdX2, storage EXT4 partition;
#  - Install Syslinux EFI in /dev/sdX1;
#  - Install OpenXT installer in /dev/sdX1;
#  - Install OpenXT installation repository in /dev/sdX2;
__prepare_installer() {
    local device="$1"
    local part_esp="${device}1"
    local part_storage="${device}2"
    local mnt="$(mktemp -d)"

    # Sanity.
    if [ "$#" -ne "1" ]; then
        echo "__prepare_installer() has no device specified." >&2
        return 1
    fi
    if [ "${UID}" -ne "0" ]; then
        echo "__prepare_installer() has to be run as root." >&2
        return 1
    fi

    set -e
    # Wipe it all. YOU WERE WARNED.
    dd bs=512 count=63 if=/dev/zero of="${device}"

    # Partition.
    parted --script "${device}" \
        mklabel gpt \
        mkpart ESP fat32 1MiB 551MiB \
        set 1 esp on \
        mkpart primary ext4 551MiB 100%

    # Format media.
    # parted will not mkfs, this is not intuitive.
    mkfs -t fat "${part_esp}"
    mkfs -t ext4 "${part_storage}"

    # Install Syslinux EFI.
    mount "${part_esp}" "${mnt}"
    mkdir -p "${mnt}/EFI/BOOT"
    cp "${host_syslinux_dir}/efi64/syslinux.efi" "${mnt}/EFI/BOOT/BOOTX64.EFI"
    for bin in mboot.c32 ldlinux.e64 libcom32.c32 ; do
        cp -v "${host_syslinux_dir}/efi64/${bin}" "${mnt}"/EFI/BOOT
    done
    # Deploy installer files.
    cp -rv "${staging_dir}/usb/syslinux" "${mnt}/"
    umount "${part_esp}"
    # Deploy repository files.
    mount "${part_storage}" "${mnt}"
    cp -rv "${staging_dir}/repository/packages.main" "${mnt}/"
    umount "${part_storage}"

    rm -r "${mnt}"
    set +e
}

# Usage: deploy_usb </dev/sdX>
# Run the required staging steps, format the /dev/sdXN partition, install the
# syslinux mbr on the device (/dev/sdX), install syslinux on it, then deploy
# the installer and installation required files on the newly created partition.
deploy_usb() {
    local sd="$1"
    local reply=""
    local attempts=5

    # Sanity.
    if [ "$#" -lt 1 ]; then
        echo "No device provided." >&2
        return 1
    fi
    if [ ! -b "${sd}" ]; then
        echo "\`${sd}' is not a block device." >&2
        return 1
    fi

    # Safeguard.
    local usb_driver="$(udevadm info --query=all -n ${sd} | sed -ne 's/E: ID_USB_DRIVER=\(.\+\)/\1/p')"

    if [ "${usb_driver}" != "usb-storage" ]; then
        echo "${sd} is not a storage USB device. Abort." >&2
        return 1
    fi

    # Last warning...
    echo -n "This will erase ${sd}, are you sure? (y/N) "
    while [ "${reply}" != "y" ]; do
        read reply
        case "${reply}" in
            ""|"n"|"N") return 0 ;;
        esac
        if [ "${attempts}" -lt 0 ]; then
            echo "" >&2
            echo "Assuming \`no'... Bailing out." >&2
            return 1
        fi
    done

    # Prepare repository layout and write XC-{PACKAGE,REPOSITORY,SIGNATURE}
    # meta files.
    stage "repository"
    # Prepare USB image layout.
    stage "usb"
    # Deploy.
    sudo su -c " \
        staging_dir=${staging_dir}; \
        host_syslinux_dir=${host_syslinux_dir}; \
        $(declare -f __prepare_installer); \
        __prepare_installer ${sd} \
    "
}

# Usage: deploy_usage
# Display usage for this command wrapper.
deploy_usage() {
    echo "Deployment command list:"
    echo "  usb-old <device-node>: Wipe and partition the device to make a BIOS/MBR bootable Syslinux OpenXT installer. This installer is available until OpenXT 7."
    echo "  iso-old: Create a BIOS/MBR bootable ISO hybrid image of an OpenXT installer (can be dd'ed on a thumbdrive). This installeris available until OpenXT 7."
    echo "  usb <devide-node>: Wipe and partition the device to make an EFI bootable Syslinux OpenXT installer. This installer is available starting with OpenXT 8."
    echo "  iso: Create an EFI bootable ISO hybrid image of an OpenXT installer (can be dd'ed on a thumbdrive). This installer is available starting with OpenXT 8."
    exit $1
}

# Usage: deploy <command>
# Deploy OpenXT on the selected installation media.
deploy() {
    target="$1"
    shift 1

    case "${target}" in
        "usb-old") check_cmd_version ${target}
                   deploy_usb_legacy $@ ;;
        "iso-old") check_cmd_version "${target}"
                   deploy_iso_legacy $@ ;;
        "usb") check_cmd_version "${target}"
               deploy_usb $@ ;;
        "iso") check_cmd_version "${target}"
               deploy_iso $@ ;;
        "help") deploy_usage 0 ;;
        *) echo "Unknown staging command \`${target}'." >&2
           deploy_usage 1
           ;;
    esac
}


# Usage: sync_usb_legacy </dev/sdXN>.
# Copy the staged file in the USB installer partition.
# This does no install the syslinux mbr or the syslinux bootloader files.
sync_usb_legacy() {
    local sd="$1"
    local mnt=`mktemp -d`

    if [ "$#" -ne 1 -o ! -b "${sd}" ]; then
        return 1
    fi

    set -e

    # Prepare repository & meta files.
    stage_repository
    # Prepare USB image layout.
    stage_usb xenclient-dom0
    sudo mount "${sd}" "${mnt}"
    # Copy the repositories
    sudo cp -ruv -T "${staging_dir}/repository/packages.main" "${mnt}/packages.main"
    # Copy the acms, installer hypervisor, kernel and initrd.
    sudo cp -ruv -T "${staging_dir}/usb/syslinux" "${mnt}/syslinux"
    sudo umount "${mnt}"

    set +e

    rm -r "${mnt}"
}

# Usage: sync <command> [args]
# Synchronize install media with what is new in the staging.
sync() {
    target=$1
    shift 1
    case "${target}" in
        "usb-old") sync_usb_legacy $@ ;;
        *) echo "Unknown sync command \`${target}'." >&2
           return 1
           ;;
    esac
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
