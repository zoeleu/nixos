# Desktop PC: AMD Radeon RX 9060 XT, 1440p @ 280 Hz, Plasma.
# NixOS on its own drive (Windows on another); LUKS full-disk encryption
# unlocked by passphrase at boot, then automatic login into zoe.
#
# Installed with the installer ISO (`install-nixos`, see installer/), which
# partitions the disk per ./disko.nix and writes ./hardware-configuration.nix
# and ./disk.nix. Until those exist the flake skips this host.
{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix # generated with --no-filesystems: disko owns the disks
    ./disko.nix
    ./disk.nix                   # which disk; written by the installer
    ./kde-apps.nix
    inputs.disko.nixosModules.disko
    inputs.claude-desktop.nixosModules.default
  ];

  # Compressed swap in RAM, used before the 32 GB swap partition
  zramSwap.enable = true;

  # --- Bluetooth (Plasma's Bluetooth settings; audio goes through PipeWire,
  # enabled for all machines in modules/common.nix) ---
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings.General.Experimental = true; # show headset/controller battery levels
  };

  # --- Boot ---
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # Newest kernel for the newest amdgpu fixes (RDNA 4 needs 6.15+; both
  # this and the LTS kernel come prebuilt from cache.nixos.org)
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # --- GPU: AMD Radeon RX 9060 XT (RDNA 4) ---
  hardware.graphics = {
    enable = true;
    enable32Bit = true; # Steam / 32-bit games
  };
  hardware.amdgpu.initrd.enable = true; # native resolution from early boot
  hardware.amdgpu.overdrive.enable = true; # allow LACT to tune power/clocks/fans
  services.lact.enable = true; # GPU monitor + fan curve / undervolt GUI
  # 2560x1440 @ 280 Hz and VRR (FreeSync) are set in Plasma's display
  # settings; nothing needed here.

  # --- Desktop: Plasma + Plasma Login Manager ---
  services.desktopManager.plasma6.enable = true;
  services.displayManager.plasma-login-manager.enable = true;
  # The disk passphrase at boot is the gate, so log straight into zoe
  services.displayManager.autoLogin = {
    enable = true;
    user = "zoe";
  };
  environment.sessionVariables.NIXOS_OZONE_WL = "1"; # Electron apps on Wayland

  # --- SSH: key only ---
  services.openssh.settings.KbdInteractiveAuthentication = false;

  # --- Gaming ---
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
    extraCompatPackages = [ pkgs.proton-ge-bin ];
  };
  programs.gamemode.enable = true;
  programs.gamescope = {
    enable = true;
    capSysNice = true;
  };

  # --- VMs for AI agents: Incus ---
  # zoe is in "incus" (not "incus-admin"): her own restricted Incus project,
  # can create/delete containers and VMs but not touch the host. Safe to let
  # agents running as zoe drive it. VMs balloon: free guest memory goes back
  # to the host.
  virtualisation.incus = {
    enable = true;
    preseed = {
      networks = [{
        name = "incusbr0";
        type = "bridge";
        config = {
          "ipv4.address" = "10.18.0.1/24";
          "ipv4.nat" = "true";
        };
      }];
      storage_pools = [{
        name = "default";
        driver = "dir";
      }];
      profiles = [{
        name = "default";
        devices = {
          eth0 = { name = "eth0"; network = "incusbr0"; type = "nic"; };
          root = { path = "/"; pool = "default"; type = "disk"; };
        };
      }];
    };
  };
  networking.nftables.enable = true; # required by Incus
  networking.firewall.trustedInterfaces = [ "incusbr0" ];

  # --- Containers: rootless Podman with a Docker-compatible CLI ---
  virtualisation.podman = {
    enable = true;
    dockerCompat = true; # `docker` command -> podman
    defaultNetwork.settings.dns_enabled = true; # containers resolve each other by name
  };

  # --- Flatpak + Flathub ---
  services.flatpak.enable = true;
  systemd.services.flatpak-flathub = {
    description = "Add the Flathub Flatpak remote";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = [ pkgs.flatpak ];
    serviceConfig.Type = "oneshot";
    script = "flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo";
  };

  # --- Claude Desktop (github:patrickjaja/claude-desktop-extra) ---
  programs.claude-desktop-extra = {
    kvmAccess.enable = true; # local Cowork VM (/dev/kvm, /dev/vhost-vsock)
    tpmAccess.enable = true; # device key in the TPM (/dev/tpmrm0 only); the TPM
                             # doesn't hold the disk key on this machine
  };
  # Keeps Claude Desktop (and other apps) signed in outside GNOME
  services.gnome.gnome-keyring.enable = true;

  users.users.zoe.extraGroups = [ "incus" ];

  # --- Apps ---
  environment.systemPackages = with pkgs; [
    inputs.claude-desktop.packages.${pkgs.stdenv.hostPlatform.system}.default
    chatgpt
    codex
    google-chrome
    bun
    nodejs_26 # current LTS
    python3
    podman-compose
    mangohud
  ];

  home-manager.users.zoe = {
    imports = [ ./home.nix ];
    home.stateVersion = "26.11"; # first install's version, never change
  };

  system.stateVersion = "26.11"; # first install's version, never change
}
