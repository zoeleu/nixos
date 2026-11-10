# Installer ISO (USB stick / Ventoy): https://nix.zoe.dev.br/nixos-zoe-installer.iso
{ lib, modulesPath, ... }:

{
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
    ./common.nix
  ];
  image.baseName = lib.mkForce "nixos-zoe-installer";
}
