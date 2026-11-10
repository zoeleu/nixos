# Steam Deck (LCD) running Jovian NixOS
{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./ccache.nix
    inputs.jovian.nixosModules.default
  ];

  # --- Boot ---
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # Kernel: Jovian's Steam Deck kernel (set by jovian.devices.steamdeck).
  boot.initrd.luks.devices."luks-70a00096-ad77-4ee4-ba6e-f712e5f52d82".device = "/dev/disk/by-uuid/70a00096-ad77-4ee4-ba6e-f712e5f52d82";

  # --- Jovian ---
  jovian.devices.steamdeck.enable = true;
  jovian.steam = {
    enable = true;
    autoStart = true;           # boot into Gaming Mode
    user = "deck";              # games run as the separate "deck" user
    desktopSession = "plasma";  # "Switch to Desktop" opens Plasma (as deck)
  };
  nix.settings.substituters = [ "https://jovian-nixos.cachix.org" ];
  nix.settings.trusted-public-keys = [
    "jovian-nixos.cachix.org-1:mAWLjAxLNlfxAnozUjOqGj4AxQwCl7MXwOfu7msVlAo="
  ];

  # Gaming user: auto-logged in by Jovian, no admin rights (not in "wheel"),
  # so it can't read zoe's files or use sudo. Steam stays logged in here.
  users.users.deck = {
    isNormalUser = true;
    description = "Steam Deck";
    extraGroups = [ "networkmanager" ]; # change wifi from Gaming Mode
    homeMode = "700";
  };

  # --- Desktop (Plasma, via Jovian's SDDM auto-login) ---
  services.xserver.enable = true;
  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;

  # --- fscrypt: zoe's home is encrypted, unlocked by the login password ---
  security.pam.enableFscrypt = true;
  environment.systemPackages = [ pkgs.fscrypt ];

  # Home Manager can't write into zoe's home while it's locked (at boot):
  # skip it then instead of failing; it runs on the next rebuild while
  # zoe is logged in.
  systemd.services.home-manager-zoe.serviceConfig.ExecCondition = toString (
    pkgs.writeShellScript "zoe-home-unlocked" ''
      ! ${pkgs.fscrypt}/bin/fscrypt status /home/zoe 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q '^Unlocked: *No'
    ''
  );

  # --- SSH ---
  # Everywhere: key AND password (the password unlocks fscrypt).
  # From Tailscale (100.64.0.0/10, fd7a:115c:a1e0::/48): password alone.
  # Tailscale's firewall drops those source addresses on other interfaces,
  # so they can't be spoofed from a local network.
  services.openssh = {
    settings = {
      KbdInteractiveAuthentication = true;
      AuthenticationMethods = "publickey,keyboard-interactive";
    };
    extraConfig = ''
      Match Address 100.64.0.0/10,fd7a:115c:a1e0::/48
        AuthenticationMethods keyboard-interactive
    '';
  };

  # --- Wifi fix (Realtek RTL8822CE / rtw88) ---
  boot.extraModprobeConfig = ''
    options rtw88_pci disable_aspm=1
    options rtw88_core disable_lps_deep=1
    options cfg80211 ieee80211_regdom=BR
  '';
  hardware.wirelessRegulatoryDatabase = true;
  networking.networkmanager.wifi.powersave = false;

  # --- Local builds: 8 threads / 16 GB -> 2 builds x 4 threads avoids swapping ---
  nix.settings.max-jobs = 2;
  nix.settings.cores = 4;

  # Jovian's patched packages that take long to compile; CI builds each in
  # its own parallel job (kernel, Mesa and PipeWire come from modules/ci.nix)
  ci.heavyPackages = with pkgs.jovianPackages; {
    inputplumber = config.services.inputplumber.package;
    inherit steamos-manager mangohud scx-scheds vpower;
  };

  home-manager.users.zoe.home.stateVersion = "26.11"; # never change
  system.stateVersion = "26.11"; # first install's version, never change
}
