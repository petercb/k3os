# syntax=docker/dockerfile:1

### BASE ###
FROM alpine:3.21 AS util
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
ARG BASE_VERSION=v1.1.0
ARG VERSION
ARG TARGETARCH

ADD --link \
    https://github.com/petercb/k3os-base/releases/download/${BASE_VERSION}/userspace-${TARGETARCH}.tar.gz \
    /tmp/

RUN tar xf /tmp/userspace-${TARGETARCH}.tar.gz -C /

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
    mksquashfs /usr/src/image /output/rootfs.squashfs -no-progress -comp zstd
EOF


### 30bin ###
FROM util AS bin

ARG K3OS_BIN_VERSION=v1.5.0
ARG K3OS_BIN_REPO=https://github.com/petercb/k3os-bin
ARG TARGETARCH

COPY --from=rootfs /output/rootfs.squashfs /usr/src/
COPY install.sh /output/k3os-install.sh
ADD --link \
    ${K3OS_BIN_REPO}/releases/download/${K3OS_BIN_VERSION}/k3os-bin_linux_${TARGETARCH}.tar.gz \
    /tmp/k3os-bin.tar.gz

RUN <<-EOF
    tar xf /tmp/k3os-bin.tar.gz -C /output/
    test -f /output/k3os
    printf "_sqmagic_" >> /output/k3os
    cat /usr/src/rootfs.squashfs >> /output/k3os
EOF


### 40kernel ###
FROM util AS kernel

ARG TARGETARCH
ARG VERSION
ARG KERNEL_VERSION

COPY --from=bin /output/k3os /usr/src/initrd/k3os/system/k3os/${VERSION}/k3os

WORKDIR /usr/src/initrd/k3os/system/k3os
RUN ln -s ${VERSION} current

WORKDIR /usr/src/initrd
RUN ln -s k3os/system/k3os/current/k3os init

ADD --link \
    https://github.com/petercb/k3os-kernel/releases/download/${KERNEL_VERSION}/k3os-kernel-${TARGETARCH}.squashfs \
    /output/kernel.squashfs
ADD --link \
    https://github.com/petercb/k3os-kernel/releases/download/${KERNEL_VERSION}/k3os-vmlinuz-${TARGETARCH}.img \
    /output/vmlinuz
ADD --link \
    https://github.com/petercb/k3os-kernel/releases/download/${KERNEL_VERSION}/k3os-kernel-version-${TARGETARCH}.txt \
    /output/version

WORKDIR /usr/src/initrd
# hadolint ignore=DL4006
RUN <<-EOF
    find . | cpio -H newc -o | gzip -c -1 > /output/initrd
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
COPY --from=kernel /output/ /output/k3os/system/kernel/

WORKDIR /output/k3os/system/kernel
RUN <<-EOF
    mkdir -vp "$(cat version)"
    ln -sf "$(cat version)" current
    mv -vf initrd kernel.squashfs current/
    rm -vf version vmlinuz
EOF


### Output ###
FROM util AS output
ARG VERSION
ARG TARGETARCH
ARG BOOT_DIR=/tmp/boot_partition

ADD --link https://github.com/raspberrypi/firmware.git#1.20241126 /tmp/firmware

COPY iso-files/rpi-live-grub.cfg ${BOOT_DIR}/efi/grub/grub.cfg
COPY iso-files/rpi-config.txt ${BOOT_DIR}/config.txt
COPY iso-files/grub.cfg /usr/src/iso/boot/grub/grub.cfg
COPY iso-files/config.yaml /usr/src/iso/k3os/system/
COPY --from=package /output/ /usr/src/${VERSION}/

WORKDIR /output
RUN tar czf k3os-rootfs-${TARGETARCH}.tar.gz -C /usr/src ${VERSION}

WORKDIR /usr/src/iso
# hadolint ignore=DL3018,DL4006,SC2086,SC3037
RUN <<-EOF
    PKGS="grub mtools"
    case "${TARGETARCH}" in
        amd64)
            PKGS="${PKGS} grub-bios xorriso"
            ;;
        arm64)
            PKGS="${PKGS} grub-efi e2fsprogs e2fsprogs-extra dosfstools sfdisk"
            ;;
    esac
    apk add --no-cache --no-progress --virtual .tools ${PKGS}
    tar xf /output/k3os-rootfs-${TARGETARCH}.tar.gz --strip-components 1
    case "${TARGETARCH}" in
        arm64)
            rm -rf boot
            cp /tmp/firmware/boot/fixup4.dat \
                /tmp/firmware/boot/start4.elf \
                /tmp/firmware/boot/bcm2711-*.dtb \
                /tmp/firmware/boot/bcm2712-*.dtb \
                "${BOOT_DIR}/"
            mkdir -p "${BOOT_DIR}/overlays"
            cp /tmp/firmware/boot/overlays/miniuart-bt.dtbo \
                /tmp/firmware/boot/overlays/upstream-pi4.dtbo \
                /tmp/firmware/boot/overlays/disable-*.dtbo \
                "${BOOT_DIR}/overlays/"
            grub-mkimage -O arm64-efi -o "${BOOT_DIR}/bootaa64.efi" \
                --prefix='/efi/grub' \
                all_video boot chain configfile disk efi_gop ext2 fat \
                gfxterm gzio linux loopback normal part_msdos search \
                search_label squash4 terminal zstd
            BOOT_SIZE=$((10 * 2048))
            ROOT_SIZE=$((230 * 2048))
            BOOT_IMG="/tmp/boot_partition.img"
            fallocate -l $((BOOT_SIZE * 512)) "${BOOT_IMG}"
            mkfs.vfat -F 16 -n K3OS_GRUB "${BOOT_IMG}"
            mcopy -bsQ -i "${BOOT_IMG}" "${BOOT_DIR}"/* ::/
            rm -rf "${BOOT_DIR}"
            ROOT_IMG="/tmp/root_partition.img"
            fallocate -l $((ROOT_SIZE * 512)) "${ROOT_IMG}"
            mke2fs -t ext4 -L K3OS_STATE -O ^has_journal,sparse_super \
                -d . -m 0 "${ROOT_IMG}"
            e2fsck -f -y "${ROOT_IMG}"
            FINAL_IMG="/output/k3os-${TARGETARCH}.img"
            fallocate -l $(((2048 + BOOT_SIZE + ROOT_SIZE) * 512)) "${FINAL_IMG}"
            echo -e "2048 ${BOOT_SIZE} 4 *\n$((BOOT_SIZE + 2048)) ${ROOT_SIZE} 83" \
                | sfdisk --label dos "${FINAL_IMG}"
            dd if="${BOOT_IMG}" of="${FINAL_IMG}" bs=512 seek=2048 conv=notrunc
            dd if="${ROOT_IMG}" of="${FINAL_IMG}" bs=512 seek=$((BOOT_SIZE + 2048)) conv=notrunc
            rm "${BOOT_IMG}" "${ROOT_IMG}"
            sfdisk -lV "${FINAL_IMG}"
            ;;
        amd64)
            grub-mkrescue -o /output/k3os-${TARGETARCH}.iso . -- \
                -volid K3OS \
                -joliet off \
                -hfsplus off \
                -rockridge on
            [ -e /output/k3os-${TARGETARCH}.iso ]
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
