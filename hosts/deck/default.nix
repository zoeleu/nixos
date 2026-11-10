# Steam Deck (LCD) running Jovian NixOS
{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./ccache.nix
    ./pxe.nix
    ./touch-unlock.nix
    inputs.jovian.nixosModules.default
  ];

  # --- Boot ---
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # Kernel: Jovian's Steam Deck kernel (set by jovian.devices.steamdeck).
  boot.initrd.luks.devices."luks-70a00096-ad77-4ee4-ba6e-f712e5f52d82".device = "/dev/disk/by-uuid/70a00096-ad77-4ee4-ba6e-f712e5f52d82";

  # --- Disk unlock: TPM, else touch keyboard (./touch-unlock.nix) ---
  # Both LUKS devices (root, swap) try the TPM first and fall back to the
  # passphrase, so nothing changes until the TPM is enrolled, once, on the
  # Deck itself:  sudo deck-tpm-enroll   (asks for the disk passphrase)
  # The passphrase keeps working afterwards. Tradeoff: with the TPM enrolled
  # the Deck boots to Gaming Mode unattended, so the disk passphrase no longer
  # protects the `deck` user's files from someone holding the Deck; zoe's
  # home stays encrypted (fscrypt, login password). Bound to PCR 7 (Secure
  # Boot state), which survives kernel and firmware updates.
  boot.initrd.availableKernelModules = [ "tpm_crb" "tpm_tis" ];
  boot.initrd.luks.devices."luks-028a1e8c-165a-4a27-84ab-0356af08b6fc".crypttabExtraOpts = [ "tpm2-device=auto" ];
  boot.initrd.luks.devices."luks-70a00096-ad77-4ee4-ba6e-f712e5f52d82".crypttabExtraOpts = [ "tpm2-device=auto" ];

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
  environment.systemPackages = [
    pkgs.fscrypt
    (pkgs.writeShellApplication {
      name = "deck-tpm-enroll";
      runtimeInputs = [ config.systemd.package ];
      text = ''
        [ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
        for uuid in 028a1e8c-165a-4a27-84ab-0356af08b6fc 70a00096-ad77-4ee4-ba6e-f712e5f52d82; do
          # replaces an earlier TPM enrolment; passphrase slots are untouched
          systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7 "/dev/disk/by-uuid/$uuid"
        done
        echo "Done. To undo: systemd-cryptenroll --wipe-slot=tpm2 <device>"
      '';
    })
  ];

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

  # Auto-updates (modules/auto-upgrade.nix) apply at the next boot, so an
  # update never restarts anything in the middle of a game
  system.autoUpgrade.operation = "boot";

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
  # Desktop Mode runs as deck: same Plasma look as zoe's
  home-manager.users.deck = {
    imports = [ ../../home/plasma.nix ];
    home.stateVersion = "26.11"; # never change
  };
  system.stateVersion = "26.11"; # first install's version, never change
}
