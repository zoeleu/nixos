# Disk layout, applied by the installer ISO (`install-nixos`, see
# installer/): wipes the disk and creates
#   1 GB  EFI boot partition (vfat)
#   32 GB swap, encrypted with a new random key every boot (no hibernation)
#   rest  LUKS2 (passphrase at boot) -> ext4 root
# The disk itself is chosen at install time and written to ./disk.nix.
{ ... }:

{
  disko.devices.disk.main = {
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "fmask=0077" "dmask=0077" ];
          };
        };
        swap = {
          size = "32G";
          content = {
            type = "swap";
            # 4K crypto sectors: one cipher call per page instead of eight.
            # New random key every boot, so this applies at the next reboot.
            randomEncryption.sectorSize = 4096;
          };
        };
        root = {
          size = "100%";
          content = {
            type = "luks";
            name = "cryptroot";
            # only read when formatting: install-nixos puts the passphrase
            # here (from Vaultwarden or typed), in RAM, and deletes it after
            passwordFile = "/tmp/disk.key";
            # 4K crypto sectors, matching ext4's 4K blocks (one cipher call per
            # block instead of eight). Only read when formatting: the current
            # install keeps 512 until moved with `nvme-4k` from the installer
            # (installer/nvme-4k.sh: backup, NVMe to 4K, restore).
            extraFormatArgs = [ "--sector-size" "4096" ];
            settings = {
              allowDiscards = true; # TRIM on the SSD
              # Encrypt/decrypt in the context that issued the IO instead of
              # dm-crypt's kcryptd workqueues: lower latency on NVMe, and the
              # IO keeps its cgroup, so BFQ weights see who it's for. Only
              # affects unlocking (crypttab), not the on-disk format.
              bypassWorkqueues = true;
            };
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
      };
    };
  };
}
