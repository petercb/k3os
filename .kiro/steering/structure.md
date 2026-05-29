# Project Structure

```
k3os/
├── .circleci/config.yml      # CI/CD pipeline definition
├── .pre-commit-config.yaml   # Pre-commit hook configuration
├── Dockerfile                # Multi-stage build (the entire build system)
├── install.sh                # OS installer script (runs on target machine)
├── scripts/                  # Build automation scripts
│   ├── build                 # Docker build wrapper
│   ├── test                  # Runs container-structure-test
│   ├── package               # Extracts artifacts from Docker to dist/
│   ├── version               # Computes version strings from git
│   └── run-qemu              # Local QEMU testing helper
├── overlay/                  # Files overlaid onto the rootfs image
│   ├── init                  # PID 1 init script (bash)
│   ├── etc/
│   │   ├── init.d/           # OpenRC service scripts
│   │   ├── conf.d/           # OpenRC service configs
│   │   ├── ssh/sshd_config   # SSH daemon configuration
│   │   ├── sysctl.d/         # Kernel parameters
│   │   └── profile.d/        # Shell profile scripts
│   ├── lib/os-release        # OS identification (templated with VERSION/ARCH)
│   ├── libexec/k3os/         # Boot-time scripts
│   │   ├── boot              # Post-bootstrap boot sequence
│   │   ├── bootstrap         # Early system bootstrap
│   │   ├── functions          # Shared shell functions
│   │   ├── live              # Live boot setup
│   │   ├── mode              # Mode dispatcher
│   │   ├── mode-disk         # Disk boot mode
│   │   ├── mode-install      # Installation mode
│   │   ├── mode-live         # Live (RAM) mode
│   │   ├── mode-local        # Local disk mode
│   │   └── mode-shell        # Emergency shell mode
│   ├── sbin/update-issue     # Generates /etc/issue at boot
│   └── share/rancher/        # k3s manifests and upgrade scripts
├── iso-files/                # Files included in bootable media
│   ├── config.yaml           # Default cloud-config for ISO
│   ├── grub.cfg              # GRUB config for ISO/disk boot
│   └── rpi-live-grub.cfg     # GRUB config for RPi4
├── cst/k3os.yaml             # Container structure test definitions
├── dist/                     # Build output artifacts (gitignored)
├── build/test-results/       # Test result XML files
├── package/packer/           # Packer templates for cloud images
│   ├── aws/                  # Amazon AMI builder
│   ├── gcp/                  # Google Cloud image builder
│   ├── hetzner/              # Hetzner Cloud image builder
│   ├── openstack/            # OpenStack image builder
│   └── proxmox/              # Proxmox VM template builder
└── examples/                 # Usage examples
    └── system-upgrade-plans/ # Kubernetes upgrade plan manifests
```

## Key Conventions

- **No host build tools required** — everything builds inside Docker
- **Scripts are bash** with `set -eu` (or `set -eux`) error handling
- **overlay/ mirrors the target filesystem** — paths map 1:1 to where files land on the running OS
- **Version is derived from git tags** — format `vX.Y.Z` maps to k3s version `v1.Y.Z+k3sN`
- **Architecture is always explicit** — files and images are suffixed with `-amd64` or `-arm64`
- **Cloud images use Packer** — each provider has its own template.json + config.yaml
