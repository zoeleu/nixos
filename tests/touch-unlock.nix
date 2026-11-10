# Boots hosts/deck/touch-unlock.nix in a VM with two LUKS disks: the
# on-screen keyboard must take the passphrase (Plymouth not in the way), both
# disks must open with one passphrase, and the splash must start afterwards.
# Based on nixpkgs' nixos/tests/systemd-initrd-luks-unl0kr.nix.
#   nix build -L .#checks.x86_64-linux.touch-unlock
{ lib, ... }:

let
  passphrase = "secret";
in
{
  name = "touch-unlock";

  nodes.machine = { pkgs, ... }: {
    imports = [ ../hosts/deck/touch-unlock.nix ];

    virtualisation = {
      emptyDiskImages = [ 512 512 ];
      useBootLoader = true;
      mountHostNixStore = true;
      useEFIBoot = true;
      qemu.options = [ "-vga virtio" ];
    };
    boot.loader.systemd-boot.enable = true;
    environment.systemPackages = [ pkgs.cryptsetup ];

    specialisation.boot-luks.configuration = {
      testing.initrdBackdoor = true;
      boot.initrd.luks.devices = lib.mkVMOverride {
        cryptroot.device = "/dev/vdb";
        cryptswap.device = "/dev/vdc"; # the Deck's second LUKS device is its swap
      };
      virtualisation.rootDevice = "/dev/mapper/cryptroot";
      virtualisation.fileSystems."/second" = {
        device = "/dev/mapper/cryptswap";
        fsType = "auto";
      };
    };
  };

  testScript = { nodes, ... }:
    let
      boot-luks = nodes.machine.specialisation.boot-luks.configuration.system.build.toplevel;
    in
    ''
      machine.wait_for_unit("multi-user.target")

      for disk, name in [("vdb", "cryptroot"), ("vdc", "cryptswap")]:
          machine.succeed(f"echo -n ${passphrase} | cryptsetup luksFormat -q --iter-time=1 /dev/{disk} -")
          machine.succeed(f"echo -n ${passphrase} | cryptsetup luksOpen -q /dev/{disk} {name}")
          machine.succeed(f"mkfs.ext4 /dev/mapper/{name}")

      machine.succeed("${boot-luks}/bin/switch-to-configuration boot")
      machine.succeed("sync")
      machine.crash()

      machine.start()
      # Only starts if Plymouth is not running in the initrd
      machine.wait_for_unit("unl0kr-agent.service")
      machine.fail("test -e /run/plymouth/pid")
      machine.screenshot("keyboard")
      machine.send_chars("${passphrase}\n")
      machine.switch_root()
      machine.wait_for_unit("multi-user.target")

      mounts = machine.succeed("mount")
      assert "/dev/mapper/cryptroot on / type ext4" in mounts, mounts
      assert "/dev/mapper/cryptswap on /second type ext4" in mounts, mounts
      # The splash ran from the real root, after unlocking
      machine.succeed("journalctl -b -u plymouth-start.service | grep -q 'Started Show Plymouth Boot Screen'")
    '';
}
