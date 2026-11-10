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
            randomEncryption = true;
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
            settings.allowDiscards = true; # TRIM on the SSD
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
