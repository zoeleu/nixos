# Standalone installer command, also runnable from an older ISO with nix run.
{ pkgs, inputs }:
pkgs.writeShellApplication {
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
    cage
    firefox
  ];
  # the repo as of this image build, if GitHub can't be reached
  runtimeEnv.ISO_REPO = "${inputs.self}";
  runtimeEnv.INSTALLER_VAULT_LIB = "${./vault-session.sh}";
  text = builtins.readFile ./install-nixos.sh;
}
