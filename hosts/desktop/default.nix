# Desktop PC: AMD Radeon RX 9060 XT, 1440p @ 280 Hz, Plasma.
# NixOS on its own drive (Windows on another); LUKS full-disk encryption
# unlocked by passphrase at boot, then automatic login into zoe.
#
# Installed with the installer ISO (`install-nixos`, see installer/), which
# partitions the disk per ./disko.nix and writes ./hardware-configuration.nix
# and ./disk.nix. Until those exist it is available only in ciConfigurations,
# using ci.nix; nixosConfigurations still requires the real generated files.
{ config, lib, pkgs, inputs, ciBuild ? false, ... }:

let
  # CachyOS kernel (Chaotic-Nyx): BORE scheduler + Clang ThinLTO, built for
  # x86-64-v3, the highest level the i7-8086K (Coffee Lake: AVX2, no
  # AVX-512) supports. This kernel has no CPU-specific -march options, and
  # NATIVE would target the CI runner's CPU, not this one.
  cachyos = let
    lto = inputs.chaotic.legacyPackages.x86_64-linux.linuxPackages_cachyos-lto;
  in lto.cachyOverride {
    cachyVars = lto.kernel.cachyConfig.cachyVars // {
      _cpusched = "bore";
      _processor_opt = "GENERIC_V3";
    };
  };
in
{
  # Not booted yet: CI builds it first (it's not in any binary cache), then
  # switch with: boot.kernelPackages = cachyos;  (replacing linuxPackages_latest)
  ci.heavyPackages = {
    cachyos-kernel = cachyos.kernel;
    claude-desktop = inputs.claude-desktop.packages.${pkgs.stdenv.hostPlatform.system}.default;
    inherit (pkgs) codex; # overlays/codex.nix, so never in cache.nixos.org
  };

  imports = [
    ./kde-apps.nix
    inputs.claude-desktop.nixosModules.default
  ] ++ lib.optionals (!ciBuild) [
    ./hardware-configuration.nix # generated with --no-filesystems: disko owns the disks
    ./disko.nix
    ./disk.nix                   # which disk; written by the installer
    inputs.disko.nixosModules.disko
  ];

  # Compressed swap in RAM, used before the 32 GB swap partition
  zramSwap.enable = true;

  # BFQ I/O scheduler on every disk (SATA SSD/HDD, NVMe, SD): keeps the
  # desktop responsive while something else hammers the disk (game installs,
  # nix builds), at a small throughput cost on fast NVMe. It's a module in
  # the kernel config (CONFIG_IOSCHED_BFQ=m), so load it before udev applies
  # the rule. LUKS/dm devices have no scheduler of their own; the disk under
  # them gets BFQ.
  boot.kernelModules = [ "bfq" ];
  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="sd[a-z]*|nvme[0-9]*n[0-9]*|mmcblk[0-9]*", ATTR{queue/scheduler}="bfq"
  '';

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
  # Boot splash (themed in modules/branding.nix); it shows the disk
  # passphrase prompt itself, typed on the keyboard as before
  boot.plymouth.enable = true;

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

  # --- sudo: no password for zoe (wheel) ---
  # The disk passphrase is the gate on this machine and SSH is key-only.
  # Anything running as zoe can become root, so untrusted code and AI agents
  # belong in Incus VMs / Podman, not in zoe's session.
  security.sudo.wheelNeedsPassword = false;

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

  # --- NFC: PN532 reader on a CP2102 USB-serial adapter (libnfc) ---
  # nfc-list, nfc-poll, nfc-mfclassic... find the reader through
  # /etc/nfc/libnfc.conf. The udev rule gives the adapter a fixed name
  # (ttyUSB numbers change) and lets whoever sits at the machine open it,
  # so no dialout group is needed.
  # numbered below 73: that's where udev turns the uaccess tag into access
  services.udev.packages = [
    (pkgs.writeTextDir "lib/udev/rules.d/70-pn532.rules" ''
      SUBSYSTEM=="tty", ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea60", SYMLINK+="pn532", TAG+="uaccess"
    '')
  ];
  environment.etc."nfc/libnfc.conf".text = ''
    allow_autoscan = false
    device.name = "PN532 (CP2102)"
    device.connstring = "pn532_uart:/dev/pn532"
  '';

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
    google-chrome
    codex
    # ChatGPT desktop app (OpenAI's Linux build; includes the Codex app),
    # using the codex above (overlays/codex.nix) instead of its bundled copy
    chatgpt
    # T3 Code (GUI for coding agents) driving Claude Code and Codex
    (t3code.override { enableClaude = true; })
    bun
    nodejs_26 # current LTS
    python3
    podman-compose
    mangohud
    usbutils # lsusb
    libnfc   # NFC tools; reader set up above
    jq
    gh # GitHub CLI (PRs, issues, CI runs)
  ];

  home-manager.users.zoe = {
    imports = [ ./home.nix ];
    home.stateVersion = "26.11"; # first install's version, never change
  };

  system.stateVersion = "26.11"; # first install's version, never change
}
