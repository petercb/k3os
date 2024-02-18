# syntax=docker/dockerfile:1.6.0

### BASE ###
FROM alpine:3.17.7 AS util
SHELL ["/bin/ash", "-euo", "pipefail", "-c"]

FROM util AS base
ARG TARGETARCH

# hadolint ignore=DL3018
RUN <<-EOF
    apk --no-cache add \
        bash \
        bash-completion \
        blkid \
        busybox-extras-openrc \
        busybox-openrc \
        ca-certificates \
        connman \
        conntrack-tools \
        coreutils \
        cryptsetup \
        curl \
        dbus \
        dmidecode \
        dosfstools \
        e2fsprogs \
        e2fsprogs-extra \
        efibootmgr \
        eudev \
        findutils \
        gcompat \
        grub-efi \
        haveged \
        hvtools \
        iproute2 \
        iptables \
        irqbalance \
        iscsi-scst \
        jq \
        kbd-bkeymaps \
        lm-sensors \
        libc6-compat \
        libusb \
        logrotate \
        lsscsi \
        lvm2 \
        lvm2-extra \
        mdadm \
        mdadm-misc \
        mdadm-udev \
        multipath-tools \
        ncurses \
        ncurses-terminfo \
        nfs-utils \
        open-iscsi \
        openrc \
        openssh-client \
        openssh-server \
        openssl \
        parted \
        procps \
        qemu-guest-agent \
        rng-tools \
        rsync \
        strace \
        strongswan \
        smartmontools \
        sudo \
        tar \
        tzdata \
        util-linux \
        virt-what \
        vim \
        wireguard-tools \
        wpa_supplicant \
        xfsprogs \
        xz
    mv -vf /etc/conf.d/qemu-guest-agent /etc/conf.d/qemu-guest-agent.orig
    mv -vf /etc/conf.d/rngd             /etc/conf.d/rngd.orig
    mv -vf /etc/conf.d/udev-settle      /etc/conf.d/udev-settle.orig
    if [ "$TARGETARCH" = "amd64" ]; then
        apk --no-cache add \
            grub-bios \
            open-vm-tools \
            open-vm-tools-deploypkg \
            open-vm-tools-guestinfo \
            open-vm-tools-static \
            open-vm-tools-vmbackup
    fi
EOF

### gobuild ###
FROM golang:1.20.12-alpine3.17 AS gobuild

ARG VERSION
ENV LINKFLAGS "-extldflags -static -s"
ENV BUILD_VERSION_FLAG "-X github.com/petercb/k3os/pkg/version.Version=$VERSION"
ENV CGO_ENABLED=0

SHELL ["/bin/ash", "-euo", "pipefail", "-c"]

WORKDIR /output


### 10k3s ###
FROM base AS k3s

ARG TARGETARCH
ENV TARGETARCH ${TARGETARCH}
ARG K3S_VERSION
ADD https://raw.githubusercontent.com/rancher/k3s/${K3S_VERSION}/install.sh /output/install.sh
ENV INSTALL_K3S_VERSION=${K3S_VERSION} \
    INSTALL_K3S_SKIP_START=true \
    INSTALL_K3S_BIN_DIR=/output
RUN <<-EOF
    chmod +x /output/install.sh
    /output/install.sh
    echo "${K3S_VERSION}" > /output/version
EOF


### 10kernel-stage1 ###
FROM ubuntu:jammy-20240125 AS kernel-stage1
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

ARG TARGETARCH
ARG KERNEL_VERSION
ARG KERNEL_URL

# Download kernel
ADD ${KERNEL_URL}/kernel-generic_${TARGETARCH}.tar.xz \
    /usr/src/kernel.tar.xz
ADD ${KERNEL_URL}/kernel-extra-generic_${TARGETARCH}.tar.xz \
    /usr/src/kernel-extra.tar.xz
ADD ${KERNEL_URL}/kernel-headers-generic_${TARGETARCH}.tar.xz \
    /usr/src/kernel-headers.tar.xz

# Install kernel build depends
# hadolint ignore=DL3008
RUN <<-EOF
    apt-get --assume-yes update
    apt-get --assume-yes install --no-install-recommends \
        initramfs-tools \
        kmod \
        rsync \
        xz-utils
    apt-get clean
    rm -rf /var/lib/apt/lists/*
    {
        echo 'r8152'
        echo 'hfs'
        echo 'hfsplus'
        echo 'nls_utf8'
        echo 'nls_iso8859_1'
    } >> /etc/initramfs-tools/modules
EOF

# Extract to /usr/src/root
WORKDIR /usr/src/root
RUN <<-EOF
    echo "Unpacking kernel..."
    tar xf /usr/src/kernel.tar.xz
    echo "Unpacking kernel-extra..."
    tar xf /usr/src/kernel-extra.tar.xz
    echo "Unpacking kernel-headers..."
    tar xf /usr/src/kernel-headers.tar.xz
    echo "rsync -aq /usr/src/root/lib/ /lib/"
    rsync -aq /usr/src/root/lib/ /lib/
EOF

# Create initrd
WORKDIR /output/lib
WORKDIR /output/headers
WORKDIR /usr/src/initrd
RUN <<-EOF
    echo "Generate initrd"
    depmod ${KERNEL_VERSION}
    mkinitramfs -c gzip -o /usr/src/initrd.tmp ${KERNEL_VERSION}
    zcat /usr/src/initrd.tmp | cpio -idm
    rm /usr/src/initrd.tmp
    echo "Generate firmware and module lists"
    find lib/modules -name \*.ko > /output/initrd-modules
    echo lib/modules/${KERNEL_VERSION}/modules.order >> /output/initrd-modules
    echo lib/modules/${KERNEL_VERSION}/modules.builtin >> /output/initrd-modules
    find lib/firmware -type f > /output/initrd-firmware
    find usr/lib/firmware -type f | sed 's!usr/!!' >> /output/initrd-firmware
EOF

# Copy output assets
WORKDIR /usr/src/root
RUN <<-EOF
    cp -r usr/src/linux-headers* /output/headers
    cp -r lib/firmware /output/lib/firmware
    cp -r lib/modules /output/lib/modules
    cp boot/System.map* /output/System.map
    cp boot/config* /output/config
    cp boot/vmlinuz-* /output/vmlinuz
    echo ${KERNEL_VERSION} > /output/version
EOF


### 20progs ###
FROM gobuild AS linuxkit
ARG LINUXKIT_VERSION=v1.0.1
ENV GO111MODULE off
ADD https://github.com/linuxkit/linuxkit.git#${LINUXKIT_VERSION} \
    "$GOPATH/src/github.com/linuxkit/linuxkit"

WORKDIR $GOPATH/src/github.com/linuxkit/linuxkit/pkg/metadata
RUN go build \
        -ldflags "$BUILD_VERSION_FLAG $LINKFLAGS" \
        -o /output/metadata

FROM gobuild AS k3os
COPY go.mod $GOPATH/src/github.com/petercb/k3os/
COPY go.sum $GOPATH/src/github.com/petercb/k3os/
COPY pkg/ $GOPATH/src/github.com/petercb/k3os/pkg/
COPY main.go $GOPATH/src/github.com/petercb/k3os/
WORKDIR $GOPATH/src/github.com/petercb/k3os
RUN go build \
        -ldflags "$BUILD_VERSION_FLAG $LINKFLAGS" \
        -mod=readonly \
        -o /output/k3os


### 20rootfs ###
FROM base AS rootfs
ARG VERSION
ARG TARGETARCH

# hadolint ignore=DL3018
RUN apk add --no-cache squashfs-tools

COPY --from=base /bin /usr/src/image/bin/
COPY --from=base /lib /usr/src/image/lib/
COPY --from=base /sbin /usr/src/image/sbin/
COPY --from=base /etc /usr/src/image/etc/
COPY --from=base /usr /usr/src/image/usr/

# Fix up more stuff to move everything to /usr
WORKDIR /usr/src/image
# hadolint ignore=DL4006,SC2086
RUN <<-EOF
    for i in usr/*; do
        if [ -e "$(basename $i)" ]; then
            tar cf - "$(basename $i)" | tar xf - -C usr
            rm -rf "$(basename $i)"
        fi
        mv $i .
    done
    rmdir usr
EOF


WORKDIR /usr/src/image/bin
RUN <<-EOF
    # Fix coreutils links
    find . -xtype l -ilname ../usr/bin/coreutils -exec ln -sf coreutils {} \;

    # Fix sudo
    chmod +s /usr/src/image/bin/sudo

    # Add empty dirs to bind mount
    mkdir -p /usr/src/image/lib/modules
    mkdir -p /usr/src/image/src

    # setup /etc/ssl
    rm -rf /usr/src/image/etc/ssl
    mkdir -p /usr/src/image/etc/ssl/certs/
    cp -rf /etc/ssl/certs/ca-certificates.crt /usr/src/image/etc/ssl/certs
    ln -s certs/ca-certificates.crt /usr/src/image/etc/ssl/cert.pem

    # setup /usr/local
    rm -rf /usr/src/image/local
    ln -s /var/local /usr/src/image/local
    # setup /usr/libexec/kubernetes
    rm -rf /usr/libexec/kubernetes
    ln -s /var/lib/rancher/k3s/agent/libexec/kubernetes \
        /usr/src/image/libexec/kubernetes

    # cleanup files hostname/hosts
    rm -rf \
        /usr/src/image/etc/hosts \
        /usr/src/image/etc/hostname \
        /usr/src/image/etc/alpine-release \
        /usr/src/image/etc/apk \
        /usr/src/image/etc/ca-certificates* \
        /usr/src/image/etc/os-release
    ln -s /usr/lib/os-release /usr/src/image/etc/os-release
    rm -rf \
        /usr/src/image/sbin/apk \
        /usr/src/image/usr/include \
        /usr/src/image/usr/lib/apk \
        /usr/src/image/usr/lib/pkgconfig \
        /usr/src/image/usr/lib/systemd \
        /usr/src/image/usr/lib/udev \
        /usr/src/image/usr/share/apk \
        /usr/src/image/usr/share/applications \
        /usr/src/image/usr/share/ca-certificates \
        /usr/src/image/usr/share/icons \
        /usr/src/image/usr/share/mkinitfs \
        /usr/src/image/usr/share/vim/vim81/spell \
        /usr/src/image/usr/share/vim/vim81/tutor \
        /usr/src/image/usr/share/vim/vim81/doc
EOF

COPY --from=k3s /output/install.sh /usr/src/image/libexec/k3os/k3s-install.sh
COPY --from=linuxkit /output/metadata /usr/src/image/sbin/metadata

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
        -e "s/%TARGETARCH%/${TARGETARCH}/g" \
        /usr/src/image/lib/os-release
    mkdir -p /output
    mksquashfs /usr/src/image /output/rootfs.squashfs
EOF


### 30bin ###
FROM util AS bin

COPY --from=rootfs /output/rootfs.squashfs /usr/src/
COPY install.sh /output/k3os-install.sh
COPY --from=k3os /output/k3os /output/k3os
RUN <<-EOF
    printf "_sqmagic_" >> /output/k3os
    cat /usr/src/rootfs.squashfs >> /output/k3os
EOF


### 40kernel ###
FROM util AS kernel
ARG VERSION

# hadolint ignore=DL3018
RUN apk add --no-cache squashfs-tools
COPY --from=kernel-stage1 /output/ /usr/src/kernel/

WORKDIR /usr/src/initrd/lib
WORKDIR /usr/src/kernel
# hadolint ignore=DL4006
RUN <<-EOF
    tar cf - -T initrd-modules -T initrd-firmware \
        | tar xf - -C /usr/src/initrd/
    depmod -b /usr/src/initrd "$(cat /usr/src/kernel/version)"
EOF

WORKDIR /output
WORKDIR /usr/src/kernel
RUN <<-EOF
    depmod -b . "$(cat /usr/src/kernel/version)"
    mksquashfs . /output/kernel.squashfs
    cp /usr/src/kernel/version /output/
    cp /usr/src/kernel/vmlinuz /output/
EOF

COPY --from=bin /output/ /usr/src/k3os/

WORKDIR /usr/src/initrd
RUN <<-EOF
    mkdir -p k3os/system/k3os/${VERSION}
    cp /usr/src/k3os/k3os k3os/system/k3os/${VERSION}
    ln -s ${VERSION} k3os/system/k3os/current
    ln -s /k3os/system/k3os/current/k3os init
EOF

WORKDIR /usr/src/initrd
# hadolint ignore=DL4006
RUN find . | cpio -H newc -o | gzip -c -1 > /output/initrd


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

# hadolint ignore=DL3018
RUN <<-EOF
    apk --no-cache add xorriso grub grub-efi mtools
    if [ "$TARGETARCH" = "amd64" ]; then
        apk --no-cache add grub-bios
    fi
EOF

WORKDIR /output
RUN grub-mkrescue -o /output/k3os.iso /usr/src/iso/. -- \
        -volid K3OS \
        -joliet on \
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
