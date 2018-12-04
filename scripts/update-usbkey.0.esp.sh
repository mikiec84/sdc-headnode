#!/usr/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# Copyright (c) 2018, Joyent, Inc.
#
# This script is run by sdc-usbkey update to copy over any new contents of
# /opt/smartdc/share/usbkey/contents/ over to the root of the USB key.
#

. /lib/sdc/usb-key.sh

set -e

loader_path="/boot/loader64.efi"
dryrun="no"
verbose="no"
update_esp="no"

function usage()
{
	echo "$0 [-nv] contentsdir mountpoint" >&2
	exit 2
}

while getopts "nv" opt; do
	case $opt in
	n) dryrun="yes" ;;
	v) verbose="yes" ;;
	*) usage ;;
	esac
done

shift $((OPTIND-1))
contents=$1
shift
mountpoint=$1

[[ -n "$contents" ]] || usage
[[ -n "$mountpoint" ]] || usage

old_boot_ver=$(cat $mountpoint/etc/version/boot 2>&1 || true)

if [[ -z "$old_boot_ver" ]]; then
	exit 0
fi

if cmp $mountpoint/$loader_path $contents/$loader_path 2>/dev/null; then
	if [[ "$verbose" = "yes" ]]; then
		echo "$loader_path is unchanged; skipping ESP update"
	fi

	exit 0
fi

if [[ "$verbose" = "yes" ]]; then
	echo "Updating loader ESP because $loader_path changed"
fi

if [[ "$dryrun" = "yes" ]]; then
	exit 0
fi

esp=$(mount_usb_key_esp)
ret=$?

if [[ $ret -ne 0 ]]; then
	exit $ret
fi

#
# An empty result means that key isn't loader-based, so there's no ESP to
# update...
#
if [[ -z "$esp" ]]; then
	if [[ "$verbose" = "yes" ]]; then
		echo "Key is legacy type; skipping ESP update"
	fi
	exit 0
fi

if ! cp -f $contents/$loader_path $esp/efi/boot/bootx64.efi; then
	echo "Failed to copy $contents/$loader_path to ESP" >&2
	umount $esp
	rmdir $esp
	exit 1
fi

if ! umount $esp; then
	echo "Failed to unmount $esp" >&2
	exit 1
fi

rmdir $esp
exit 0
