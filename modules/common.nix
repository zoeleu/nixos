# Shared by every machine in ./hosts
{ config, lib, pkgs, ... }:

{
  # --- Nix ---
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;

  # Our own binary cache, filled by GitHub Actions (.github/workflows/build.yml).
  # TODO: create the cache on cachix.org, then fill in its name and public key:
  # nix.settings.substituters = [ "https://CACHE-NAME.cachix.org" ];
  # nix.settings.trusted-public-keys = [ "CACHE-NAME.cachix.org-1:PUBLIC-KEY" ];

  # --- Locale ---
  time.timeZone = "America/Sao_Paulo";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "pt_BR.UTF-8";
    LC_IDENTIFICATION = "pt_BR.UTF-8";
    LC_MEASUREMENT = "pt_BR.UTF-8";
    LC_MONETARY = "pt_BR.UTF-8";
    LC_NAME = "pt_BR.UTF-8";
    LC_NUMERIC = "pt_BR.UTF-8";
    LC_PAPER = "pt_BR.UTF-8";
    LC_TELEPHONE = "pt_BR.UTF-8";
    LC_TIME = "pt_BR.UTF-8";
  };
  services.xserver.xkb = {
    layout = "us";
    variant = "intl";
  };
  console.keyMap = "us-acentos";

  # --- Networking ---
  networking.networkmanager.enable = true;
  services.tailscale.enable = true; # log in once with: sudo tailscale up

  # --- Sound ---
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  services.printing.enable = true;

  # --- User ---
  programs.fish.enable = true;
  users.users.zoe = {
    isNormalUser = true;
    description = "Zoe Leullier";
    extraGroups = [ "networkmanager" "wheel" ];
    homeMode = "700";
    shell = pkgs.fish;
    packages = with pkgs; [
      kdePackages.kate
    ];
    # Keys in /etc (not ~/.ssh) so sshd can read them even if home is locked.
    # Source: https://github.com/zoeleu.keys
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDASV5glPTSjwJmpiM9Cs2uU4+rke4vJxWXSZHhkjj/x3nTkE847O8QxJV63J92WlzbP9PDwp4/YYIMPQGE1NGFAKjgFBLKPJ7Ej7utvaiOxtc/4cut7BSNUOcCvzId+rw2SmtZGoxmJ6nZUu7HLK5ADxcgRNyL9DFUChyYinIBVujXPbFG94dKF7gELPxXlcXgi1nQkYmquDDO25ZSyu3FcynFbHBH3Iq2ke2t6Eek+gtWpddoF1MDzVRUDTBgywqozgWe24MtH7dHJSY12pMZxUc70NOvP5IV3svA1C+1Wj8vyCRMuqLypeMMtURbWzwD4JWZC9ZQHHBrYGgeMx2QxAgFFhRd6OCyGRh3WPCqIkMg+Hjdcg1GSvXhePYrBCNA7miNXjzb2IVvVrL8KvLl6C/eJK/zREZitUgOcGFbObYAybLAJ+2RQfMjCkrCa34xluzvm8lOLFpW9tQWW+6//hFvRvRlo8+6naXYu198eTdC9inw9XcUjHqg0mvCVJc="
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPFBvsaG6aPotHAV12xNw0uZKRGSyyE99aC/qEhPzNwD"
    ];
  };

  # --- Home Manager (zoe's dotfiles: git, ssh, Bitwarden agent, ...) ---
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "hm-backup"; # move pre-existing files aside instead of failing
    users.zoe = ../home/common.nix;    # hosts add their own parts + home.stateVersion
  };

  # --- SSH (each host sets how users authenticate) ---
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
  };

  # --- Programs ---
  programs.firefox.enable = true;
  programs.nix-ld.enable = true; # run downloaded (non-Nix) Linux binaries

  environment.systemPackages = with pkgs; [
    claude-code
    git # this config is a git repo
  ];
}
