# syntax=docker/dockerfile:1

### BASE ###
FROM alpine:3.17.7 AS util
SHELL ["/bin/ash", "-euo", "pipefail", "-c"]

ARG TARGETARCH

# hadolint ignore=DL3018,DL3019
RUN <<-EOF
    apk update
    apk add squashfs-tools openrc xorriso grub grub-efi mtools
    if [ "$TARGETARCH" = "amd64" ]; then
        apk add grub-bios
    fi
    rm -rf /var/cache/apk/*
EOF


### 10k3s ###
FROM util AS k3s

ARG TARGETARCH
ENV TARGETARCH ${TARGETARCH}
ARG K3S_VERSION=v1.27.11+k3s1

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

RUN <<-EOF
    ln -s /k3os/system/k3os/current/k3os /usr/src/image/sbin/k3os
    ln -s /k3os/system/k3s/current/k3s /usr/src/image/sbin/k3s
    ln -s k3s /usr/src/image/sbin/kubectl
    ln -s k3s /usr/src/image/sbin/crictl
    ln -s k3s /usr/src/image/sbin/ctr
EOF

COPY install.sh /usr/src/image/libexec/k3os/install
RUN <<-EOF
    sed -i -e "s/%VERSION%/${VERSION}/g" \
        -e "s/%ARCH%/${TARGETARCH}/g" \
        /usr/src/image/lib/os-release
    mkdir -p /output
    mksquashfs /usr/src/image /output/rootfs.squashfs
EOF


### 30bin ###
FROM util AS bin

ARG K3OS_BIN_VERSION=v1.3.2
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
ARG FLATCAR_VERSION=3975.2.2

COPY --from=bin /output/ /tmp/k3os/

WORKDIR /output

ADD --link \
    https://stable.release.flatcar-linux.net/${TARGETARCH}-usr/${FLATCAR_VERSION}/flatcar_production_image.vmlinuz \
    /output/vmlinuz

ADD --link \
    https://stable.release.flatcar-linux.net/${TARGETARCH}-usr/${FLATCAR_VERSION}/flatcar-container.tar.gz \
    /tmp/

WORKDIR /tmp/flatcar

RUN <<-EOF
    tar xf /tmp/flatcar-container.tar.gz
    cp usr/lib/modules/*/build/include/config/kernel.release /output/version
EOF

WORKDIR /usr/src/kernel

# hadolint ignore=DL4006
RUN <<-EOF
    mkdir -p lib
    mv /tmp/flatcar/usr/lib/firmware ./lib/
    mv /tmp/flatcar/usr/lib/modules ./lib/
    cp /output/version ./
    cp /output/vmlinuz ./
    mksquashfs . /output/kernel.squashfs
    KERNEL_VERSION="$(cat /output/version)"
    export KERNEL_VERSION
    find lib/modules -name \*.ko.xz > /tmp/initrd-modules
    echo "lib/modules/${KERNEL_VERSION}/modules.order" >> /tmp/initrd-modules
    echo "lib/modules/${KERNEL_VERSION}/modules.builtin" >> /tmp/initrd-modules
    find lib/firmware -type f > /tmp/initrd-firmware
    mkdir -p /usr/src/initrd/lib
    tar cf - -T /tmp/initrd-modules -T /tmp/initrd-firmware \
        | tar xf - -C /usr/src/initrd/
    depmod -b /usr/src/initrd "${KERNEL_VERSION}"
EOF

WORKDIR /usr/src/initrd

# hadolint ignore=DL4006
RUN <<-EOF
    mkdir -p k3os/system/k3os/${VERSION}
    cp /tmp/k3os/k3os k3os/system/k3os/${VERSION}
    ln -s ${VERSION} k3os/system/k3os/current
    ln -s /k3os/system/k3os/current/k3os init
    find . | cpio -H newc -o | gzip -c -1 > /output/initrd
EOF




### 50package ###
FROM util AS package
ARG VERSION

COPY --from=k3s /output/  /output/k3os/system/k3s/
COPY --from=bin /output/  /output/k3os/system/k3os/${VERSION}/

WORKDIR /output/k3os/system/k3s
RUN <<-EOF
    mkdir -vp "$(cat version)" /output/sbin
    mv -vf crictl ctr kubectl /output/sbin/
    ln -sf "$(cat version)" current
    mv -vf install.sh current/k3s-install.sh
    mv -vf k3s current/
    rm -vf version ./*.sh
    ln -sf /k3os/system/k3s/current/k3s /output/sbin/k3s
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
RUN grub-mkrescue -o /output/k3os.iso /usr/src/iso/. -- \
        -volid K3OS \
        -joliet off \
        -hfsplus off \
    # grub-mkrescue doesn't exit non-zero on failure
    && [ -e /output/k3os.iso ]


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
ENV PATH /k3os/system/k3os/current:/k3os/system/k3s/current:${PATH}
ENTRYPOINT ["k3os"]
CMD ["help"]
