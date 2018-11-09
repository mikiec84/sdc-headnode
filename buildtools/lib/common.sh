#!/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright 2018 Joyent, Inc.
#

#
# On Darwin (Mac OS X), trying to extract a tarball into a PCFS mountpoint
# fails, as a result of tar trying create the `.` (dot) directory. This
# appears to be a bug in how Mac implementes PCFS. Regardless, the
# workaround to this is to include every directory and file with a name
# that's longer than 2 characters. (`--exclude` doesn't seem to work on
# Mac).
#
if [[ $(uname) = "Darwin" ]]; then
	TAR="tar --include=?*"
elif [[ $(uname) = "SunOS" ]]; then
	# We must specify gtar, otherwise we will use the tar that ships
	# with illumos.
	TAR="gtar"
else
	TAR="tar"
fi

PLATFORM=$(uname -s)

if [[ "$PLATFORM" == "SunOS" ]]; then
    SUCMD='pfexec'
elif [[ "$PLATFORM" == "Darwin" ]]; then
    SUCMD='sudo'
elif [[ "$PLATFORM" == "Linux" ]]; then
    SUCMD='sudo'
fi

function fatal
{
    echo "$(basename $0): fatal error: $*"
    exit 1
}

function errexit
{
    [[ $1 -ne 0 ]] || exit 0
    fatal "error exit status $1 at line $2"
}

trap 'errexit $? $LINENO' EXIT

function rel2abs () {
    local abs_path end
    abs_path=$(unset CDPATH; cd `dirname $1` 2>/dev/null && pwd -P)
    [[ -z "$abs_path" ]] && return 1
    end=$(basename $1)
    echo "${abs_path%*/}/$end"
}

#
# The USB Image uses the GPT partitioning scheme and has the following slices:
#
# slice 1 - EFI System Partition (PCFS)
# slice 2 - Boot partition (no filesystem)
# slice 3 - Root partition (PCFS)
# slice 9 - reserved
#
# For our purposes, we want to mount slice 3, as that's where we'll be
# installing the platform image and other required software.
#
# Under SmartOS, we can't use labeled lofi or any other method to directly
# access the root filesystem, so we need to work from a temporary image.
#
function mount_root_image
{
    echo -n "==> Mounting new USB image... "
    if [[ "$PLATFORM" == "Darwin" ]]; then
        [ ! -d ${ROOT}/cache/tmp_volumes ] && mkdir -p ${ROOT}/cache/tmp_volumes
        ${SUCMD} hdiutil attach -nomount \
            -imagekey diskimage-class=CRawDiskImage \
            $IMG_TMP_DIR/${OUTPUT_IMG} >/tmp/output.hdiattach.$$ 2>&1
        LOOPBACK=`grep "GUID_partition_scheme" /tmp/output.hdiattach.$$ \
            | awk '{ print $1 }'`
        MNT_DIR=$(mktemp -d ${ROOT}/cache/tmp_volumes/root.XXXX)
        ${SUCMD} mount -t msdos ${LOOPBACK}s3 $MNT_DIR
    elif [[ "$PLATFORM" == "Linux" ]]; then
        # XXX - might need to fix this up
        MNT_DIR="/tmp/sdc_image.$$"
        mkdir -p "$MNT_DIR"
        LOOPBACK=$IMG_TMP_DIR/${OUTPUT_IMG}
        OFFSET=$(parted -s -m "${LOOPBACK}" unit B print | grep fat32:root \
            | cut -f2 -d: | sed 's/.$//')
        ${SUCMD} mount -o "loop,offset=${OFFSET},uid=${EUID},gid=${GROUPS[0]}" \
            "${LOOPBACK}" "${MNT_DIR}"
    else
        ${SUCMD} mkdir -p ${MNT_DIR}
        ROOTOFF=$(nawk '$1 == "root" { print $3 }' <$IMG_TMP_DIR/$PARTMAP)
        ROOTSIZE=$(nawk '$1 == "root" { print $4 }' <$IMG_TMP_DIR/$PARTMAP)
        ${SUCMD} /usr/bin/dd bs=1048576 conv=notrunc \
            iseek=$(( $ROOTOFF / 1048576 )) count=$(( $ROOTSIZE / 1048576 )) \
            if=$IMG_TMP_DIR/${OUTPUT_IMG} of=$IMG_TMP_DIR/rootfs.img
        ${SUCMD} mount -F pcfs -o foldcase ${IMG_TMP_DIR}/rootfs.img ${MNT_DIR}
    fi
    echo "rootfs mounted on ${MNT_DIR}"
}

function unmount_loopback
{
    if ${SUCMD} mount | grep $MNT_DIR >/dev/null; then
        ${SUCMD} umount $MNT_DIR
    fi

    if [[ -n "$LOOPBACK" && "$PLATFORM" == "Darwin" ]]; then
        ${SUCMD} hdiutil detach ${LOOPBACK} || /usr/bin/true
    fi

    sync; sync
    LOOPBACK=
}

#
# On SmartOS, we need to copy our root fs back over into the original image
# file.
#
function unmount_root_image
{
    unmount_loopback

    if [[ "$PLATFORM" = "SunOS" ]]; then
        ROOTOFF=$(nawk '$1 == "root" { print $3 }' <$IMG_TMP_DIR/$PARTMAP)
        ROOTSIZE=$(nawk '$1 == "root" { print $4 }' <$IMG_TMP_DIR/$PARTMAP)

        ${SUCMD} /usr/bin/dd bs=1048576 conv=notrunc \
            oseek=$(( $ROOTOFF / 1048576 )) count=$(( $ROOTSIZE / 1048576 )) \
            if=$IMG_TMP_DIR/rootfs.img of=$IMG_TMP_DIR/${OUTPUT_IMG}
    fi
}
