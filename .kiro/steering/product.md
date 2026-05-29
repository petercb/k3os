# Product: k3OS

k3OS is a minimal Linux distribution designed to run [k3s](https://k3s.io) (lightweight Kubernetes). It is a hard fork of the [original Rancher k3os project](https://github.com/rancher/k3os) which has been discontinued.

## Purpose

- Provides a purpose-built, immutable OS for running Kubernetes clusters via k3s
- Boots directly into k3s with minimal overhead
- Supports bare-metal, VM, and cloud deployments (AWS, GCP, Hetzner, OpenStack, Proxmox)
- Supports AMD64 and ARM64 architectures (including Raspberry Pi 4)

## Key Concepts

- **Immutable rootfs**: The root filesystem is delivered as a squashfs image
- **Cloud-config**: System configuration via YAML cloud-config files
- **Boot modes**: live, disk, install, local, shell
- **System Upgrade Controller**: Supports in-cluster OS upgrades via Kubernetes plans
- **Overlay filesystem**: Runtime customizations layered on top of the immutable base

## Maintained By

GitHub user `petercb` — container images published to `ghcr.io/petercb/k3os`.
