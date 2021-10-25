#!/usr/bin/env bash
# Copyright (c) 2021, NVIDIA CORPORATION. All rights reserved.

set -eu

DRIVER_TOOLKIT_SHARED_DIR=/mnt/shared-nvidia-driver-toolkit

echo "Running $*"

nv-ctr-run-with-dtk() {
    set -x

    if [[ "${RHCOS_IMAGE_MISSING:-}" == "true" ]]; then
        echo "WARNING: RHCOS '${RHCOS_VERSION:-}' imagetag missing, using entitlement-based fallback"
        exec bash -x nvidia-driver init
    fi

    if [[ ! -f "$DRIVER_TOOLKIT_SHARED_DIR/dir_prepared" ]]; then
        cp -r \
           /tmp/install.sh \
           /tmp/ocp_dtk_entrypoint.sh \
           /usr/local/bin/nvidia-driver \
           /usr/local/bin/extract-vmlinux \
           /usr/bin/kubectl \
           /usr/local/bin/vgpu-util \
           /drivers \
           /licenses \
           "$DRIVER_TOOLKIT_SHARED_DIR/"

        env | sed 's/=/="/' | sed 's/$/"/' > "$DRIVER_TOOLKIT_SHARED_DIR/env"

        touch "$DRIVER_TOOLKIT_SHARED_DIR/dir_prepared"
    fi

    set +x
    while [[ ! -f "$DRIVER_TOOLKIT_SHARED_DIR/driver_build_started" ]]; do
        echo "$(date) Waiting for openshift-driver-toolkit-ctr container to start ..."
        sleep 15
    done

    echo "$(date) openshift-driver-toolkit-ctr started."

    while [[ ! -f "$DRIVER_TOOLKIT_SHARED_DIR/driver_built" ]]; do
        echo "$(date) Waiting for openshift-driver-toolkit-ctr container to build the precompiled driver ..."
        sleep 15
    done
    set -x

    MODULES_SHARED=${DRIVER_TOOLKIT_SHARED_DIR}/modules/

    # Copy the modules to their standard location
    MODULES_LOCAL="/lib/modules/$(uname -r)"
    mkdir -p "${MODULES_LOCAL}"

    cp -rv "${MODULES_SHARED}"/* "${MODULES_LOCAL}"

    # tell SELinux to allow loading these files
    find . -type f \
         \( -name "*.txt" -or -name "*.go" \) \
         -exec chcon -t modules_object_t "{}" \;

    echo "#"
    echo "# Executing nvidia-driver load script ..."
    echo "#"

    exec bash -x nvidia-driver load
}

dtk-build-driver() {
    if [[ "${RHCOS_IMAGE_MISSING:-}" == "true" ]]; then
        echo "WARNING: 'istag/driver-toolkit:${RHCOS_VERSION} -n openshift' missing, nothing to do in openshift-driver-toolkit-ctr container"
        sleep +inf
    fi

    # Shared directory is prepared before entering this script. See
    # 'until [ -f /mnt/shared-nvidia-driver-toolkit/dir_prepared ] ...'
    # in the Pod command/args

    touch "$DRIVER_TOOLKIT_SHARED_DIR/driver_build_started"

    if [ -f "$DRIVER_TOOLKIT_SHARED_DIR/driver_built" ]; then
        echo "NVIDIA drivers already generated, nothing to do ..."

        while [ -f "$DRIVER_TOOLKIT_SHARED_DIR/driver_built" ]; do
            sleep 30
        done
        echo "WARNING: driver_built flag disappeared, rebuilding the drivers ..."
    else
        echo "Start building nvidia.ko driver ..."
    fi

    set -x
    set -o allexport
    source "${DRIVER_TOOLKIT_SHARED_DIR}/env"
    set +o allexport;

    # if this directory already exists,
    # NVIDIA-Linux-$DRIVER_ARCH-$DRIVER_VERSION.run fails to run
    # and doesn't create its files. This may happen when the
    # container fails and restart its execution, leading to
    # hard-to-understand "unrelated" errors in the following of the script execution

    rm -rf "${DRIVER_TOOLKIT_SHARED_DIR}/drivers/NVIDIA-Linux-${DRIVER_ARCH}-${DRIVER_VERSION}";

    # elfutils-libelf-devel.x86_64 is already install in the DTK and enough
    sed 's/elfutils-libelf.x86_64//' -i "${DRIVER_TOOLKIT_SHARED_DIR}/nvidia-driver"
    # install script assumes these directories can be deleted->recreated,
    # but recreation doesn't happen in the DTK
    sed 's|rm -rf /lib/modules/${KERNEL_VERSION}/video||' -i "${DRIVER_TOOLKIT_SHARED_DIR}/nvidia-driver"
    sed 's|rm -rf /lib/modules/${KERNEL_VERSION}||' -i "${DRIVER_TOOLKIT_SHARED_DIR}/nvidia-driver"

    mkdir "${DRIVER_TOOLKIT_SHARED_DIR}/bin" -p

    cp -v \
       "$DRIVER_TOOLKIT_SHARED_DIR/nvidia-driver" \
       "$DRIVER_TOOLKIT_SHARED_DIR/extract-vmlinux" \
       "${DRIVER_TOOLKIT_SHARED_DIR}/bin"

    ln -s $(which true) ${DRIVER_TOOLKIT_SHARED_DIR}/bin/dnf --force

    export PATH="${DRIVER_TOOLKIT_SHARED_DIR}/bin:$PATH";

    # install.sh script is mandatory
    cp "${DRIVER_TOOLKIT_SHARED_DIR}/install.sh" /tmp/

    cd "${DRIVER_TOOLKIT_SHARED_DIR}/drivers";
    echo "#"
    echo "# Executing nvidia-driver build script ..."
    echo "#"
    bash -x "${DRIVER_TOOLKIT_SHARED_DIR}/nvidia-driver" build --tag builtin

    echo "#"
    echo "# nvidia-driver build script completed."
    echo "#"

    drivers=$(ls /lib/modules/"$(uname -r)"/kernel/drivers/video/nvidia*.ko)
    if ! ls ${drivers} 2>/dev/null; then
        echo "FATAL: no NVIDIA driver generated ..."
        exit 1
    fi

    MODULES_SHARED="${DRIVER_TOOLKIT_SHARED_DIR}/modules"
    mkdir -p "${MODULES_SHARED}"

    # prepare the list of modules required by NVIDIA

    modprobe -a i2c_core ipmi_msghandler ipmi_devintf --show-depends > ${MODULES_SHARED}/insmod_nvidia
    modprobe -a nvidia nvidia-uvm nvidia-modeset --show-depends >> ${MODULES_SHARED}/insmod_nvidia

    set +x

    # copy the modules to the shared directory
    while read line; do
        if [[ "$line" == "builtin "* ]]; then
            #eg: line="builtin i2c_core"
            continue
        fi
        # eg: line="insmod /lib/modules/4.18.0-305.10.2.el8_4.x86_64/kernel/drivers/gpu/drm/drm.ko.x"
        modsrc=$(echo "${line}" | awk '{ print $2}')
        moddir=$(dirname "$(echo "${modsrc}" | sed "s|/lib/modules/$(uname -r)/||")")
        moddst="${MODULES_SHARED}/${moddir}"
        mkdir -p "${moddst}"
        cp -v "${modsrc}" "${moddst}"
    done <<< $(cat "${MODULES_SHARED}/insmod_nvidia")

    # copies modules location and dependency files
    cp /lib/modules/$(uname -r)/modules.* "${MODULES_SHARED}"

    echo "NVIDIA drivers generated, inform nvidia-driver-ctr container about it and sleep forever."
    touch "${DRIVER_TOOLKIT_SHARED_DIR}/driver_built"

    while [ -f "$DRIVER_TOOLKIT_SHARED_DIR/driver_built" ]; do
        sleep 30
    done

    echo "WARNING: driver_built flag disappeared, restart this container"

    exit 0
}

usage() {
    cat >&2 <<EOF
Usage: $0 COMMAND

Commands:
  dtk-build-driver
  nv-ctr-run-with-dtk
EOF
    exit 1
}
if [ $# -eq 0 ]; then
    usage
fi
command=$1; shift
case "${command}" in
    dtk-build-driver) options="" ;;
    nv-ctr-run-with-dtk) options="" ;;
    *) usage ;;
esac
if [ $? -ne 0 ]; then
    usage
fi
eval set -- "${options}"

if ! [ -d "${DRIVER_TOOLKIT_SHARED_DIR:-}" ]; then
    echo "FATAL: DRIVER_TOOLKIT_SHARED_DIR env variable must be populated with a valid directory"
    usage
fi

if [ $# -ne 0 ]; then
    usage
fi

$command
