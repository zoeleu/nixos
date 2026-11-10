# Network-boot installer: kernel + initrd (the whole installer, loaded into
# RAM) + an iPXE script, published at https://nix.zoe.dev.br/netboot/.
# PCs on the home LAN reach it through the Deck's PXE helper
# (hosts/deck/pxe.nix). Needs a few GB of RAM on the target.
{ modulesPath, ... }:

{
  imports = [
    "${modulesPath}/installer/netboot/netboot-minimal.nix"
    ./common.nix
  ];
  system.stateVersion = "26.11"; # a live system; set only to silence the warning
}
