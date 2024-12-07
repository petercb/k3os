# Default bootargs
setenv bootargs ''
load ${devtype} ${devnum}:${distro_bootpart} 0x02000000 bootaa64.efi
bootefi 0x02000000
