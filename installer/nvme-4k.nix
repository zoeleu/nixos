# `nvme-4k`: move an NVMe drive to 4K sectors, keeping its contents (backup
# to another disk, `nvme format`, restore). See the top of nvme-4k.sh.
# On the installer ISO, and from anywhere with
#   nix run github:zoeleu/nixos#nvme-4k -- /dev/nvme0n1 /dev/sdX
{ pkgs }:
pkgs.writeShellApplication {
  name = "nvme-4k";
  runtimeInputs = with pkgs; [
    nvme-cli
    cryptsetup
    e2fsprogs  # e2image, e2fsck, resize2fs, dumpe2fs
    dosfstools # mkfs.vfat
    util-linux # sfdisk, blkid, lsblk, wipefs, partx, mkswap
    systemd    # udevadm
    jq
    coreutils
    findutils  # xargs
    gnugrep
    gnused
    gawk
  ];
  text = builtins.readFile ./nvme-4k.sh;
}
