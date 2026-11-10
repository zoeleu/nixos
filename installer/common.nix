# The installer, shared by the ISO (iso.nix) and the network-boot image
# (netboot.nix): `install-nixos` (see install-nixos.sh) plus what it needs.
# Both are public downloads: free software only.
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
      sops          # re-encrypt secrets for the new machine
      ssh-to-age
      yq-go
      openssh       # ssh-keygen (host key)
      jq
    ];
    # the repo as of this image build, if GitHub can't be reached
    runtimeEnv.ISO_REPO = "${inputs.self}";
    text = builtins.readFile ./install-nixos.sh;
  };
in
{

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
