# PXE helper for installing machines on the home LAN (192.168.1.0/24) over
# the network. The TIM router can't set PXE options, so the Deck answers PXE
# boot requests itself in dnsmasq "proxy-DHCP" mode: the router still hands
# out all IP addresses; the Deck only adds "boot iPXE from me".
#
#   PC network boot -> iPXE from the Deck (TFTP) -> iPXE downloads the
#   installer from https://nix.zoe.dev.br/netboot/ -> install-nixos
#
# Works on whichever interface is on 192.168.1.0/24 (wifi now, the dock's
# Ethernet later). dnsmasq's DNS server is off.
{ pkgs, ... }:

let
  # iPXE with a built-in script: get an address, then load the installer
  ipxe = pkgs.ipxe.override {
    embedScript = pkgs.writeText "nixos-installer.ipxe" ''
      #!ipxe
      dhcp
      echo
      echo Loading the NixOS installer from https://nix.zoe.dev.br/netboot/ ...
      echo (about 2 GB; then run install-nixos)
      chain https://nix.zoe.dev.br/netboot/netboot.ipxe || shell
    '';
  };

  tftpRoot = pkgs.runCommand "pxe-tftp-root" { } ''
    mkdir $out
    # dnsmasq adds ".0" to BIOS boot file names
    cp ${ipxe}/undionly.kpxe $out/undionly.0
    cp ${ipxe}/ipxe.efi $out/ipxe.efi
  '';
in
{
  services.dnsmasq = {
    enable = true;
    resolveLocalQueries = false; # don't become the Deck's DNS resolver
    settings = {
      port = 0; # no DNS server
      dhcp-range = [ "192.168.1.0,proxy" ]; # answer PXE only; the router does addresses
      pxe-prompt = [ ''"NixOS installer: booting from the network",3'' ];
      pxe-service = [
        ''x86PC,"NixOS installer (BIOS)",undionly''
        ''X86-64_EFI,"NixOS installer (UEFI)",ipxe.efi''
        ''BC_EFI,"NixOS installer (UEFI)",ipxe.efi''
      ];
      enable-tftp = true;
      tftp-root = "${tftpRoot}";
      log-dhcp = true;
    };
  };

  networking.firewall.allowedUDPPorts = [
    67 # DHCP (proxy)
    69 # TFTP
    4011 # PXE
  ];
}
