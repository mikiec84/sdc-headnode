#!/usr/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright (c) 2018, Joyent, Inc.
#

function fatal
{
    echo "`basename $0`: $*" >&2
    exit 1
}

# BASHSTYLED
usbmnt="/mnt/$(svcprop -p 'joyentfs/usb_mountpoint' svc:/system/filesystem/smartdc:default)"

readonly alldisks=$(/usr/bin/disklist -a)
#
# Older MBR/GRUB-based USB keys will have a single primary partition containing
# the root filesystem.  Newer, GPT/Loader-based USB keys will have multiple
# slices with the root partition at slice 2.  We don't currently have a good
# way of knowing in advance which style of USB key we're dealing with, so we
# search for both possibilities.
#
readonly partitions=("p1" "s2")

for disk in ${alldisks}; do
    for part in ${partitions[@]}; do
        if [[ `/usr/sbin/fstyp /dev/dsk/${disk}${part}` == 'pcfs' ]]; then
            /usr/sbin/mount -F pcfs -o foldcase,noatime /dev/dsk/${disk}${part} \
                ${usbmnt};
            if [[ $? == "0" ]]; then
                if [[ ! -f ${usbmnt}/.joyliveusb ]]; then
                    /usr/sbin/umount ${usbmnt};
                else
		    found_key=1
                    break;
                fi
            fi
        fi
    done
    [[ $found_key == 1 ]] && break
done

mount | grep "^${usbmnt}" >/dev/null 2>&1 || fatal "${usbmnt} is not mounted"
