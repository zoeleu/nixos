# Build-only profile for CI before this machine's hardware is committed.
# Never imported by nixosConfigurations or the installer. Do not boot this
# system: its disposable root exists only to evaluate/build the full closure.
{ lib, ... }:

{
  nixpkgs.hostPlatform = "x86_64-linux";
  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
  };
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
  boot.loader.grub.enable = lib.mkForce false;
  system.nixos.tags = [ "ci-only" ];
}
