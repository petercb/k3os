# Tech Stack & Build System

## Core Technologies

- **Base OS**: Alpine Linux 3.23 (rootfs), Ubuntu-based kernel image
- **Container Runtime**: Docker with BuildKit (multi-stage, multi-arch)
- **Kubernetes**: k3s (lightweight Kubernetes distribution)
- **Shell**: Bash scripts for build tooling, ash/busybox at runtime
- **Init System**: OpenRC
- **Filesystem**: squashfs (immutable images), ext4 (state partition)
- **Bootloader**: GRUB (EFI + BIOS on amd64, EFI on arm64)

## Build System

The entire build is Docker-based using a multi-stage Dockerfile. No host-level compilation — everything runs inside containers.

### Key Build Args

| Arg | Purpose |
|-----|---------|
| `K3S_VERSION` | k3s release to bundle |
| `KERNEL_VERSION` | Kernel image tag from `ghcr.io/petercb/k3os-kernel` |
| `BASE_VERSION` | Alpine userspace tarball version |
| `K3OS_BIN_VERSION` | k3os CLI binary version from `petercb/k3os-bin` |

### Build Commands

```bash
# Build the container image (uses scripts/version for tagging)
scripts/build

# Run container structure tests
scripts/test

# Extract build artifacts (ISO, initrd, kernel, rootfs) to dist/
scripts/package

# Print version info
scripts/version
```

### Dockerfile Stages

1. `util` — Alpine base with build tools (cpio, openrc, squashfs-tools)
2. `k3s` — Downloads and installs k3s
3. `rootfs` — Assembles the root filesystem squashfs
4. `bin` — Builds the k3os binary (appends rootfs squashfs)
5. `kernel` — Builds initrd with dracut, packages kernel + firmware as squashfs
6. `package` — Assembles the full system layout with symlinks
7. `output` — Creates distributable artifacts (ISO for amd64, disk image for arm64)
8. `image` — Final minimal container image (FROM scratch)

## CI/CD

- **Platform**: CircleCI
- **Orbs**: `circleci/github-cli@2`, `circleci/docker@2`
- **Executors**: `amd64` (cimg/go:1.20, large), `arm64` (cimg/go:1.20, arm.large)
- **Registry**: `ghcr.io`
- **Test results**: JUnit XML via container-structure-test, stored at `build/test-results/`

### CI Workflows

- `continuous` — Builds RC on every push (no push to registry)
- `publish` — Builds + pushes on master branch
- `release` — Builds, pushes, creates GitHub release with artifacts on tags matching `v*`

## Testing

- **Container Structure Tests** (`cst/k3os.yaml`): Validates the built container image (command tests, file existence)
- **Tool**: [container-structure-test](https://github.com/GoogleContainerTools/container-structure-test)

## Linting & Pre-commit Hooks

| Tool | Purpose |
|------|---------|
| `shellcheck` | Shell script linting (severity: warning+) |
| `yamllint` | YAML linting (relaxed preset) |
| `codespell` | Spell checking |
| `circleci config validate` | CircleCI config validation |
| `pre-commit-hooks` | Trailing whitespace, line endings, large files, shebangs |

### Run pre-commit locally

```bash
pre-commit run --all-files
```

## Output Artifacts (in `dist/`)

- `k3os-{arch}.iso` — Bootable ISO (amd64 only)
- `k3os-rpi4-{arch}.img` — Raspberry Pi 4 disk image (arm64 only)
- `k3os-initrd-{arch}` — Initial ramdisk
- `k3os-kernel-{arch}.squashfs` — Kernel + modules + firmware
- `k3os-rootfs-{arch}.tar.gz` — Root filesystem archive
- `k3os-vmlinuz-{arch}` — Linux kernel binary
- `sha256sum-{arch}.txt` — Checksums
