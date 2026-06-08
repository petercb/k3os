# syntax=docker/dockerfile:1

ARG KERNEL_VERSION=latest
ARG TARGETARCH

### BASE ###
FROM alpine:3.23 AS util
SHELL ["/bin/ash", "-euo", "pipefail", "-c"]

ARG TARGETARCH

# hadolint ignore=DL3018
RUN apk add --no-cache --no-progress cpio openrc squashfs-tools


### 10k3s ###
FROM util AS k3s

ARG TARGETARCH
ARG K3S_VERSION

ADD --link \
    https://raw.githubusercontent.com/rancher/k3s/${K3S_VERSION}/install.sh \
    /output/install.sh

ENV INSTALL_K3S_VERSION=${K3S_VERSION} \
    INSTALL_K3S_SKIP_START=true \
    INSTALL_K3S_BIN_DIR=/output

RUN <<-EOF
    chmod +x /output/install.sh
    /output/install.sh
    echo "${K3S_VERSION}" > /output/version
EOF


### 20rootfs ###
FROM util AS rootfs
ARG BASE_VERSION
ARG VERSION
ARG TARGETARCH

ADD --link --unpack=true \
    https://github.com/petercb/k3os-base/releases/download/${BASE_VERSION}/userspace-${TARGETARCH}.tar.gz \
    /

COPY --from=k3s /output/install.sh /usr/src/image/libexec/k3os/k3s-install.sh

COPY overlay/ /usr/src/image/

WORKDIR /usr/src/image/sbin
RUN <<-EOF
    ln -s /k3os/system/k3os/current/k3os k3os
    ln -s /k3os/system/k3s/current/k3s k3s
    ln -s k3s kubectl
    ln -s k3s crictl
    ln -s k3s ctr
EOF

COPY install.sh /usr/src/image/libexec/k3os/install
RUN <<-EOF
    sed -i -e "s/%VERSION%/${VERSION}/g" \
        -e "s/%ARCH%/${TARGETARCH}/g" \
        /usr/src/image/lib/os-release
    mkdir -p /output
    mksquashfs /usr/src/image /output/rootfs.squashfs -no-progress -comp gzip
EOF


### 30bin ###
FROM util AS bin

ARG K3OS_BIN_VERSION
ARG K3OS_BIN_REPO=https://github.com/petercb/k3os-bin
ARG TARGETARCH

COPY --from=rootfs /output/rootfs.squashfs /usr/src/
COPY install.sh /output/k3os-install.sh
ADD --link --unpack=true \
    ${K3OS_BIN_REPO}/releases/download/${K3OS_BIN_VERSION}/k3os-bin_linux_${TARGETARCH}.tar.gz \
    /output/

RUN <<-EOF
    test -f /output/k3os
    printf "_sqmagic_" >> /output/k3os
    cat /usr/src/rootfs.squashfs >> /output/k3os
EOF


### 40kernel ###
FROM ghcr.io/petercb/k3os-kernel:${KERNEL_VERSION}-${TARGETARCH} AS kernel

ARG TARGETARCH
ARG VERSION

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# hadolint ignore=DL3008
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    <<-EOF
    #!/bin/bash
    rm -f /etc/apt/apt.conf.d/docker-clean
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache
    apt-get update
    PKGS=(
        dracut-core
        linux-firmware-amd-graphics
        linux-firmware-misc
        linux-firmware-realtek
        squashfs-tools
    )
    case "${TARGETARCH}" in
        amd64) PKGS+=(
            amd64-microcode
            intel-microcode
            linux-firmware-amd-misc
            linux-firmware-intel-misc
            linux-firmware-intel-graphics
        ) ;;
        arm64) PKGS+=(linux-firmware-raspi) ;;
        *) echo "Unknown architecture: ${TARGETARCH}"; exit 1 ;;
    esac
    echo "Installing packages: ${PKGS[*]}"
    apt-get install -y --no-install-recommends "${PKGS[@]}"
EOF

COPY --from=bin /output/k3os /usr/src/initrd/k3os/system/k3os/${VERSION}/k3os

WORKDIR /usr/src/initrd/k3os/system/k3os
RUN ln -s ${VERSION} current

WORKDIR /usr/src/initrd
RUN ln -s k3os/system/k3os/current/k3os init

WORKDIR /output
# hadolint ignore=DL4006
RUN <<-EOF
    dracut \
        --force \
        --gzip \
        --early-microcode \
        --no-hostonly \
        --modules "kernel-modules" \
        --kernel-only \
        --kver "${KVER}" \
        --include /usr/src/initrd / \
        -v
    mv "/boot/initrd.img-${KVER}" ./initrd
    ls -lFah
    lsinitrd initrd
EOF

# Make squashfs
WORKDIR /tmp/squashroot
RUN <<-EOF
    # Copy only the firmware we need
    mkdir -p lib/firmware
    firmware_count=0
    while IFS= read -r fw_path; do
        [ -z "${fw_path}" ] && continue

        # Use a bash array to expand globs safely (handles internal and suffix wildcards)
        shopt -s nullglob
        files=( /lib/firmware/${fw_path}* )
        shopt -u nullglob

        if [ ${#files[@]} -eq 0 ]; then
            echo "[WARN] Firmware not found: ${fw_path}"
            continue
        fi

        for src in "${files[@]}"; do
            rel="${src#/lib/firmware/}"
            dst="lib/firmware/${rel}"
            if [ -d "$src" ]; then
                # Directory entry (e.g., i915/, amdgpu/) — copy whole dir
                mkdir -p "${dst}"
                cp -a "${src}/." "${dst}/"
            else
                mkdir -p "$(dirname "${dst}")"
                cp -a "${src}" "${dst}"
            fi
            firmware_count=$((firmware_count + 1))
        done
    done < /boot/firmware-list.txt
    echo "Copied ${firmware_count} firmware entries (selective)"
    cp -a /lib/modules lib/modules
    cp /boot/System.map ./
    cp /boot/config ./
    cp /boot/kversion ./version
    cp /boot/vmlinuz ./
    mksquashfs . /output/kernel.squashfs -no-progress -info
    mv vmlinuz /output/
    mv version /output/
    rm -rf ./*
EOF



### 50package ###
FROM util AS package
ARG VERSION
ARG K3S_VERSION

COPY --from=k3s /output/  /output/k3os/system/k3s/${K3S_VERSION}/
COPY --from=bin /output/  /output/k3os/system/k3os/${VERSION}/

WORKDIR /output/sbin
WORKDIR /output/k3os/system/k3s
RUN <<-EOF
    ln -sf "${K3S_VERSION}" current
    ln -sf /k3os/system/k3s/current/k3s /output/sbin/k3s
EOF

WORKDIR /output/k3os/system/k3s/${K3S_VERSION}
RUN <<-EOF
    mv crictl ctr kubectl /output/sbin/
    mv install.sh k3s-install.sh
    rm -vf version k3s-uninstall.sh
EOF

WORKDIR /output/k3os/system/k3os
RUN <<-EOF
    ln -sf ${VERSION} current
    ln -sf /k3os/system/k3os/current/k3os /output/sbin/k3os
    ln -sf k3os /output/sbin/init
EOF

### 60package ###
COPY --from=kernel /output/version /tmp/version

WORKDIR /output/k3os/system/kernel
RUN <<-EOF
    mkdir -vp "$(cat /tmp/version)"
    ln -sf "$(cat /tmp/version)" current
    rm /tmp/version
EOF

COPY --from=kernel /output/initrd current/
COPY --from=kernel /output/kernel.squashfs current/


### Output ###
FROM util AS output
ARG VERSION
ARG TARGETARCH
ARG BOOT_DIR=/tmp/boot_partition

ADD --link \
    https://github.com/pftf/RPi4/releases/download/v1.41/RPi4_UEFI_Firmware_v1.41.zip \
    /tmp/firmware.zip

COPY iso-files/rpi-live-grub.cfg ${BOOT_DIR}/efi/grub/grub.cfg
COPY --from=package /output/ /usr/src/${VERSION}/

WORKDIR /output
RUN tar czf k3os-rootfs-${TARGETARCH}.tar.gz -C /usr/src ${VERSION}

COPY iso-files/grub.cfg /usr/src/${VERSION}/boot/grub/grub.cfg
COPY iso-files/config.yaml /usr/src/${VERSION}/k3os/system/

WORKDIR /usr/src/${VERSION}
# hadolint ignore=DL3018,DL4006,SC2086,SC3037
RUN <<-EOF
    PKGS="grub grub-efi mtools xorriso"
    case "${TARGETARCH}" in
        amd64)
            PKGS="${PKGS} grub-bios"
            ;;
        arm64)
            PKGS="${PKGS} e2fsprogs e2fsprogs-extra dosfstools sfdisk unzip"
            ;;
    esac
    apk add --no-cache --no-progress --virtual .tools ${PKGS}

    # Build ISO for all architectures (used for QEMU testing and live boot)
    grub-mkrescue -o /output/k3os-${TARGETARCH}.iso . -- -volid K3OS
    [ -e /output/k3os-${TARGETARCH}.iso ]

    case "${TARGETARCH}" in
        arm64)
            # Additionally build the RPi4 disk image for SD card flashing
            rm -rf boot
            mkdir -p k3os/data/opt
            echo "/dev/xxx 99" > k3os/system/growpart
            unzip -d "${BOOT_DIR}/" /tmp/firmware.zip
            mkdir -p "${BOOT_DIR}/efi/boot"
            grub-mkimage -O arm64-efi -o "${BOOT_DIR}/efi/boot/bootaa64.efi" \
                --prefix='/efi/grub' \
                all_video boot chain configfile disk efi_gop ext2 fat \
                gfxterm gzio iso9660 linux loopback normal part_msdos search \
                search_label squash4 terminal
            BOOT_SIZE=$((10 * 2048))
            BOOT_IMG="/tmp/boot_partition.img"
            fallocate -l $((BOOT_SIZE * 512)) "${BOOT_IMG}"
            mkfs.vfat -n K3OS_GRUB "${BOOT_IMG}"
            mcopy -bsQ -i "${BOOT_IMG}" "${BOOT_DIR}"/* ::/
            rm -rf "${BOOT_DIR}"

            # calculate size of root disk
            ROOT_SIZE=$(du -csk . | tail -1 | cut -f1)
            echo "Root source file size = ${ROOT_SIZE} kB blocks"
            # A safe floor for a standard ext4 journal is about 20MB (20480 KB)
            # We also add a small 2% margin for the inode table
            ROOT_SIZE=$((ROOT_SIZE + 25600 + (ROOT_SIZE * 2 / 100)))
            # Convert KB to 512B sectors
            ROOT_SIZE=$((ROOT_SIZE * 2))

            ROOT_IMG="/tmp/root_partition.img"
            echo "Creating ${ROOT_IMG} of ${ROOT_SIZE} 512B blocks"
            fallocate -l $((ROOT_SIZE * 512)) "${ROOT_IMG}"
            # Use -m 0 to disable the 5% root reservation (since it's being expanded later)
            mke2fs -t ext4 -L K3OS_STATE -m 0 -O ^orphan_file -d . "${ROOT_IMG}"
            e2fsck -f -y "${ROOT_IMG}"
            tune2fs -l "${ROOT_IMG}"

            FINAL_IMG="/output/k3os-rpi4-${TARGETARCH}.img"
            fallocate -l $(((2048 + BOOT_SIZE + ROOT_SIZE) * 512)) "${FINAL_IMG}"
            echo -e "2048 ${BOOT_SIZE} c\n$((BOOT_SIZE + 2048)) ${ROOT_SIZE} 83" \
                | sfdisk --label dos "${FINAL_IMG}"
            dd if="${BOOT_IMG}" of="${FINAL_IMG}" bs=512 seek=2048 conv=notrunc
            dd if="${ROOT_IMG}" of="${FINAL_IMG}" bs=512 seek=$((BOOT_SIZE + 2048)) conv=notrunc
            rm "${BOOT_IMG}" "${ROOT_IMG}"
            sfdisk -lV "${FINAL_IMG}"
            ;;
    esac
    rm -rf ./*
    apk del .tools
EOF

WORKDIR /output
COPY --from=kernel /output/vmlinuz k3os-vmlinuz-${TARGETARCH}
COPY --from=kernel /output/initrd k3os-initrd-${TARGETARCH}
COPY --from=kernel /output/kernel.squashfs k3os-kernel-${TARGETARCH}.squashfs
COPY --from=kernel /output/version k3os-kernel-version-${TARGETARCH}
RUN find . -type f -exec sha256sum {} \; > sha256sum-${TARGETARCH}.txt


### Main ###
FROM scratch AS image
COPY --from=package /output/k3os/system/ /k3os/system/
ENV PATH=/k3os/system/k3os/current:/k3os/system/k3s/current:${PATH}
ENTRYPOINT ["k3os"]
CMD ["help"]
