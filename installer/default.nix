# Installer ISO: the minimal NixOS ISO plus `install-nixos`, which installs
# a machine from this repo (see install-nixos.sh). Built and published by
# .github/workflows/iso.yml. It's a public download: free software only.
{ config, lib, pkgs, modulesPath, inputs, ... }:

let
  install-nixos = pkgs.writeShellApplication {
    name = "install-nixos";
    runtimeInputs = with pkgs; [
      inputs.disko.packages.${pkgs.stdenv.hostPlatform.system}.disko
      nixos-install-tools
      git
      curl
      util-linux
      coreutils
      findutils
      gnugrep
      gawk
      gnused
      bitwarden-cli # Vaultwarden passwords
      procps        # pkill (closing the SSO kiosk)
      ncurses       # clear
      jq
    ];
    # the repo as of this ISO build, if GitHub can't be reached
    runtimeEnv.ISO_REPO = "${inputs.self}";
    text = builtins.readFile ./install-nixos.sh;
  };
in
{
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix" ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = false; # public download: free software only
  networking.networkmanager.enable = true; # `nmtui` for wifi

  environment.systemPackages = [
    install-nixos
    pkgs.git
    # SSO login to Vaultwarden: install-nixos shows Firefox full-screen in cage
    pkgs.cage
    pkgs.firefox
  ];
  # the minimal ISO turns these off; Firefox needs them
  hardware.graphics.enable = true;
  fonts.fontconfig.enable = lib.mkForce true;
  fonts.enableDefaultPackages = true;

  # Shown on the console after boot
  services.getty.helpLine = lib.mkAfter ''

    To install a machine from github.com/zoeleu/nixos, run:  install-nixos
    (Ethernet connects automatically; wifi: nmtui)
  '';

  image.baseName = lib.mkForce "nixos-zoe-installer";
}
