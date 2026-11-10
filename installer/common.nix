# The installer, shared by the ISO (iso.nix) and the network-boot image
# (netboot.nix): `install-nixos` (see install-nixos.sh) plus what it needs.
# Both are public downloads: free software only.
{ config, lib, pkgs, modulesPath, inputs, ... }:

let
  install-nixos = import ./package.nix { inherit pkgs inputs; };
in
{

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = false; # public download: free software only
  networking.networkmanager.enable = true; # `nmtui` for wifi

  environment.systemPackages = [
    install-nixos
    (pkgs.writeShellApplication {
      name = "resume-nixos";
      runtimeInputs = [ install-nixos ];
      text = ''exec install-nixos --resume "$@"'';
    })
    pkgs.git
    # SSO login to Vaultwarden: install-nixos shows Firefox full-screen in cage
    pkgs.cage
    pkgs.firefox
  ];
  # the minimal installer profile turns these off; Firefox needs them
  hardware.graphics.enable = true;
  fonts.fontconfig.enable = lib.mkForce true;
  fonts.enableDefaultPackages = true;

  # Shown on the console after boot
  services.getty.helpLine = lib.mkAfter ''

    To install a machine from github.com/zoeleu/nixos, run:  install-nixos
    (Ethernet connects automatically; wifi: nmtui)
  '';

}
