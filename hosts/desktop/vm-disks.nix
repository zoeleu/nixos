{ pkgs, ... }:

{
  # The Samsung 850 EVO SATA SSD is baseplate-dev's whole disk (raw block
  # device, `incus config device ... ssd`, boot.priority=10), outside the
  # NVMe's VM IO ceilings in ./priorities.nix. zoe's restricted project
  # only allows disk sources under restricted.devices.disk.paths, and Incus
  # opens those beneath the allowed directory without following symlinks,
  # so /dev/disk/by-id/... (-> ../../sdX) is rejected and allowing /dev
  # would hand the project every host disk. Instead udev keeps one device
  # node for this disk alone in /dev/incus-disks (sdX can move between
  # boots, so it's made from the serial), and the project allows that
  # directory: set once by hand with
  #   sudo incus project set user-1000 restricted.devices.disk.paths=/home/zoe,/dev/incus-disks
  services.udev.packages = let
    vmDiskNode = pkgs.writeShellScript "incus-vm-disk-node" ''
      ${pkgs.coreutils}/bin/mkdir -p /dev/incus-disks
      ${pkgs.coreutils}/bin/rm -f "/dev/incus-disks/$1"
      ${pkgs.coreutils}/bin/mknod -m 660 "/dev/incus-disks/$1" b "$2" "$3"
      ${pkgs.coreutils}/bin/chgrp disk "/dev/incus-disks/$1"
    '';
  in [
    # after 60-persistent-storage.rules, which sets ID_SERIAL_SHORT
    (pkgs.writeTextDir "lib/udev/rules.d/90-incus-vm-disks.rules" ''
      ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", ENV{ID_SERIAL_SHORT}=="S21HNXAGC23492K", RUN+="${vmDiskNode} baseplate-dev $major $minor"
      ACTION=="remove", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", ENV{ID_SERIAL_SHORT}=="S21HNXAGC23492K", RUN+="${pkgs.coreutils}/bin/rm -f /dev/incus-disks/baseplate-dev"
    '')
  ];
}
