#!/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright (c) 2018, Joyent, Inc.
#

set -o errexit
set -o pipefail
# BASHSTYLED
#export PS4='[\D{%FT%TZ}] ${BASH_SOURCE}:${LINENO}: ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
#set -o xtrace

function fatal()
{
        printf "%s\n" "$1" 1>&2
        exit 1
}

function usage()
{
    print -u2 "Usage: $0 <platform buildstamp>"
    print -u2 "(eg. '$0 20110318T170209Z')"
    exit 1
}

if [[ "$1" = "-n" ]]; then
    dryrun=true
    shift
fi

function onexit
{
    if [[ ${mounted} == "true" ]]; then
        echo "==> Unmounting USB Key"
        /opt/smartdc/bin/sdc-usbkey unmount
        [ $? != 0 ] && fatal "failed to unmount USB key"
    fi

    echo "==> Done!"
}

function config_loader
{
    local readonly kernel="i86pc/kernel/amd64/unix"
    local readonly archive="i86pc/amd64/boot_archive"
    local readonly tmpconf=$(mktemp /tmp/loader.conf.XXXX)
    local readonly tmpmenu=$(mktemp /tmp/menu.rc.XXXX)

    echo "==> Updating Loader configuration"

    cp ${usbmnt}/boot/loader.conf.tmpl $tmpconf

    echo "bootfile=\"/os/$version/platform/$kernel\"" >> $tmpconf
    echo "boot_archive_name=\"/os/$version/platform/$archive\"" >> $tmpconf
    echo "boot_archive.hash_name=\"/os/$version/platform/${archive}.hash\"" \
        >> $tmpconf

    #
    # Check whether the currently running (soon-to-be previous) version still
    # exists on the USB key, as it's possible that we're being run because
    # we were assigned a new version and the current version was deleted.  If
    # that's the case, look for the next most recent PI and use that as the
    # default rollback target.  If there's no other options - i.e. there's now
    # only one PI remaining on the key - then we don't create a rollback entry
    # at all.
    #
    local rollback_vers=$current_version
    if [[ ! -d $usbmnt/os/$rollback_vers ]]; then
        rollback_vers=$(ls -1 $usbmnt/os | tr "[:lower:]" "[:upper:]" | \
            grep -v $version | sort | tail -1)
    fi

    if [[ -n $rollback_vers ]]; then
        echo "prev-platform=\"/os/$rollback_vers/platform/$kernel\"" \
            >> $tmpconf
        echo "prev-archive=\"/os/$rollback_vers/platform/$archive\"" \
            >> $tmpconf
        echo "prev-hash=\"/os/$rollback_vers/platform/${archive}.hash\"" \
            >> $tmpconf
    fi

    #
    # Preserve Loader and OS console settings from the previous config.
    #
    grep ^console= ${usbmnt}/boot/loader.conf >> $tmpconf
    grep ^os_console= ${usbmnt}/boot/loader.conf >> $tmpconf

    #
    # Expand the macros for PLATFORM and PREV_PLATFORM (if one exists) in
    # menu.rc into the actual platform image versions.
    #
    if [[ -n $rollback_vers ]]; then
        cat ${usbmnt}/boot/forth/menu.rc.tmpl | \
            sed -e "s|#PLATFORM|${version}|" | \
            sed -e "s|#PREV_PLATFORM|${rollback_vers}|" >> $tmpmenu
    else
        cat ${usbmnt}/boot/forth/menu.rc.noroll.tmpl | \
            sed -e "s|#PLATFORM|${version}|" >> $tmpmenu
    fi

    #
    # If it's a dryrun, just print the new Loader configuration.  Otherwise,
    # copy the new configuration into place.
    #
    if [[ -n "${dryrun}" ]]; then
        cat $tmpconf
    else
        cp -f $tmpconf ${usbmnt}/boot/loader.conf
        cp -f $tmpmenu ${usbmnt}/boot/forth/menu.rc
    fi

    rm -f $tmpconf $tmpmenu
}

function config_grub
{
    echo "==> Creating new GRUB configuration"
    if [[ -z "${dryrun}" ]]; then
        rm -f ${usbmnt}/boot/grub/menu.lst
        tomenulst=">> ${menulst}"
    fi
    while read input; do
        set -- $input
        if [[ "$1" = "#PREV" ]]; then
            _thisversion="${current_version}"
        else
            _thisversion="${version}"
        fi
        output=$(echo "$input" | sed \
            -e "s|/PLATFORM/|/os/${version}/platform/|" \
            -e "s|/PREV_PLATFORM/|/os/${current_version}/platform/|" \
            -e "s|PREV_PLATFORM_VERSION|${current_version}|" \
            -e "s|^#PREV ||")
        set -- $output
        if [[ "$1" = "module" ]] && [[ "${2##*.}" = "hash" ]] && \
            [[ ! -f "${usbcpy}/os/${_thisversion}${hashfile}" ]]; then
            continue
        fi
        eval echo '${output}' "${tomenulst}"
    done < "${menulst}.tmpl"
}

version=$1
[[ -z ${version} ]] && usage

# -U is a private option to bypass cnapi update during upgrade.
UPGRADE=0
while getopts "U" opt
do
    case "$opt" in
        U) UPGRADE=1 ;;
        *)
            print -u2 "invalid option"
            usage
            ;;
    esac
done
shift $(($OPTIND - 1))

current_version=$(uname -v | cut -d '_' -f 2)

# BEGIN BASHSTYLED
usbmnt="/mnt/$(svcprop -p 'joyentfs/usb_mountpoint' svc:/system/filesystem/smartdc:default)"
usbcpy="$(svcprop -p 'joyentfs/usb_copy_path' svc:/system/filesystem/smartdc:default)"
# END BASHSTYLED
mounted="false"
hashfile="/platform/i86pc/amd64/boot_archive.hash"
menulst="${usbmnt}/boot/grub/menu.lst"
loader_conf="${usbmnt}/boot/loader.conf"

mnt_status=$(/opt/smartdc/bin/sdc-usbkey status)
[ $? != 0 ] && fatal "failed to get USB key status"
if [[ $mnt_status = "unmounted" ]]; then
    echo "==> Mounting USB key"
    /opt/smartdc/bin/sdc-usbkey mount
    [ $? != 0 ] && fatal "failed to mount USB key"
    mounted="true"
fi

trap onexit EXIT

[[ ! -d ${usbmnt}/os/${version} ]] && \
    fatal "==> FATAL ${usbmnt}/os/${version} does not exist."


#
# XXX - Change this logic to look at MBR version
#
if [[ -f ${loader_conf} ]]; then
	config_loader
elif [[ -f ${menulst} ]]; then
	config_grub
else
	fatal "===> FATAL no boot loader configuration found"
fi

# If upgrading, skip cnapi update, we're done now.
[ $UPGRADE -eq 1 ] && exit 0

echo "==> Updating cnapi"
. /lib/sdc/config.sh
load_sdc_config

uuid=`curl -s http://${CONFIG_cnapi_admin_ips}/servers | \
    json -a headnode uuid | nawk '{if ($1 == "true") print $2}' 2>/dev/null`

[[ -z "${uuid}" ]] && \
    fatal "==> FATAL unable to determine headnode UUID from cnapi."

if [[ -n "${dryrun}" ]]; then
	doit="echo"
fi

${doit} curl -s http://${CONFIG_cnapi_admin_ips}/servers/${uuid} \
    -X POST -d boot_platform=${version} >/dev/null 2>&1

exit 0
