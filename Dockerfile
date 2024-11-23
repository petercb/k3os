# syntax=docker/dockerfile:1

### BASE ###
FROM alpine:3.17.7 AS util
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
    mksquashfs /usr/src/image /output/rootfs.squashfs -no-progress
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
ARG KERNEL_VERSION=5.15.0-126.1

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
ADD --link \
    https://github.com/petercb/k3os-kernel/releases/download/${KERNEL_VERSION}/k3os-initrd-${TARGETARCH}.gz \
    /tmp/initrd.gz

WORKDIR /usr/src/initrd
# hadolint ignore=DL4006
RUN <<-EOF
    zcat /tmp/initrd.gz | cpio -idm usr/lib/modules* usr/lib/firmware*
    mv usr/lib ./
    rmdir usr
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


### 70iso ###
FROM util AS iso
ARG VERSION
ARG TARGETARCH

COPY iso-files/grub.cfg /usr/src/iso/boot/grub/grub.cfg
COPY iso-files/config.yaml /usr/src/iso/k3os/system/
COPY --from=package /output/ /usr/src/iso/

WORKDIR /output
WORKDIR /usr/src/iso
# grub-mkrescue doesn't exit non-zero on failure
# hadolint ignore=DL3018,SC2086
RUN <<-EOF
    PKGS="grub grub-efi mtools xorriso"
    [ "${TARGETARCH}" = "amd64" ] && PKGS="${PKGS} grub-bios"
    apk add --no-cache --no-progress ${PKGS}
    if [ "${TARGETARCH}" = "arm64" ]
    then
        echo "arm_64bit=1" > boot/config.txt
        mkdir -p EFI/BOOT
        grub-mkimage -O arm64-efi -o EFI/BOOT/BOOTAA64.EFI \
            --prefix='/boot/grub' \
            efi_gop linux ext2 part_gpt part_msdos normal boot chain configfile
        xorriso -as mkisofs -o /output/k3os.iso \
            -V K3OS \
            -e EFI/BOOT/BOOTAA64.EFI \
            -no-emul-boot -boot-load-size 4 -boot-info-table \
            .
    else
        grub-mkrescue -o /output/k3os.iso . -- \
            -volid K3OS \
        && [ -e /output/k3os.iso ]
    fi
EOF



### 80tar ###
FROM util AS tar
ARG VERSION

COPY --from=package /output/   /usr/src/${VERSION}/
WORKDIR /output
RUN tar czvf userspace.tar.gz -C /usr/src ${VERSION}


### Full ###
FROM util AS output
ARG TARGETARCH

WORKDIR /output
COPY --from=kernel /output/vmlinuz k3os-vmlinuz-${TARGETARCH}
COPY --from=kernel /output/initrd k3os-initrd-${TARGETARCH}
COPY --from=kernel /output/kernel.squashfs k3os-kernel-${TARGETARCH}.squashfs
COPY --from=kernel /output/version k3os-kernel-version-${TARGETARCH}
COPY --from=iso /output/k3os.iso k3os-${TARGETARCH}.iso
COPY --from=tar /output/userspace.tar.gz k3os-rootfs-${TARGETARCH}.tar.gz
RUN find . -type f -exec sha256sum {} \; > sha256sum-${TARGETARCH}.txt


### Main ###
FROM scratch AS image
COPY --from=package /output/k3os/system/ /k3os/system/
ENV PATH=/k3os/system/k3os/current:/k3os/system/k3s/current:${PATH}
ENTRYPOINT ["k3os"]
CMD ["help"]
