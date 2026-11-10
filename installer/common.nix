# The installer, shared by the ISO (iso.nix) and the network-boot image
# (netboot.nix). It boots into a kiosk: sway with every window as a tab, and
# the graphical installer (gui.py) in the first one. The GUI drives
# `install-nixos` (install-nixos.sh), which still works alone on a console
# (Ctrl+Alt+F2).
#
# Both images are public downloads: free software only. The two unfree things
# the installer offers (Widevine for Chromium, i.e. Spotify; Claude Code for
# troubleshooting) are not on the image: installer-extras.service downloads
# them from their vendors once there is a network.
{ config, lib, pkgs, modulesPath, inputs, ... }:

let
  install-nixos = import ./package.nix { inherit pkgs inputs; };
  artwork = pkgs.callPackage ../pkgs/artwork.nix { };
  extras = "/run/installer-extras";

  python = pkgs.python3.withPackages (ps: [ ps.pygobject3 ]);
  gui = pkgs.stdenv.mkDerivation {
    name = "installer-gui";
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.wrapGAppsHook4 pkgs.gobject-introspection ];
    buildInputs = [ pkgs.gtk4 pkgs.libadwaita ];
    installPhase = ''
      install -Dm755 ${./gui.py} $out/bin/installer-gui
      substituteInPlace $out/bin/installer-gui \
        --replace-fail "#!/usr/bin/env python3" "#!${python}/bin/python3"
      ${python}/bin/python3 -m py_compile $out/bin/installer-gui
    '';
    preFixup = ''
      gappsWrapperArgs+=(
        --set-default ISO_REPO ${inputs.self}
        --set INSTALLER_ACCENT '${artwork.accent}'
        --set INSTALLER_ACCENT_LIGHT '${artwork.accentLight}'
      )
    '';
  };

  # Chromium: the one with Widevine once it's downloaded, else the image's
  browser = pkgs.writeShellApplication {
    name = "installer-browser";
    text = ''
      chromium=${extras}/chromium/bin/chromium
      [ -x "$chromium" ] || chromium=${pkgs.chromium}/bin/chromium
      exec "$chromium" --no-first-run --no-default-browser-check --ozone-platform=wayland "$@"
    '';
  };
  browserDesktop = pkgs.makeDesktopItem {
    name = "installer-browser";
    desktopName = "Chromium";
    exec = "installer-browser %U";
    mimeTypes = [ "x-scheme-handler/http" "x-scheme-handler/https" "text/html" ];
  };

  # Claude Code in ~/install-help, where troubleshooting.md is its CLAUDE.md
  claude = pkgs.writeShellApplication {
    name = "installer-claude";
    text = ''
      claude=${extras}/claude/bin/claude
      if [ ! -x "$claude" ]; then
        echo "Claude Code isn't on the installer image; downloading it (needs internet)..."
        sudo systemctl start installer-extras.service || true # waits for the download
      fi
      if [ ! -x "$claude" ]; then
        echo "The download failed. Check the network, then: journalctl -u installer-extras"
        read -rp "Press Enter to close. " _
        exit 1
      fi
      mkdir -p "$HOME/install-help"
      cd "$HOME/install-help"
      install -m 644 ${./troubleshooting.md} CLAUDE.md
      exec "$claude" "$@"
    '';
  };

  swayConfig = pkgs.writeText "installer-sway.conf" ''
    font pango:DejaVu Sans 11
    workspace_layout tabbed
    default_border normal 0
    titlebar_padding 14 8
    hide_edge_borders both
    focus_follows_mouse no
    #                       border            background        text     indicator
    client.focused          ${artwork.accent} ${artwork.accent} #101213  ${artwork.accent}
    client.focused_inactive #20302e           #20302e           #dddddd  #20302e
    client.unfocused        ${artwork.background} ${artwork.background} #aaaaaa ${artwork.background}
    output * bg ${artwork.wallpaper} fill
    input type:keyboard {
      xkb_layout us
      xkb_variant intl
    }
    input type:touchpad {
      tap enabled
      natural_scroll enabled
    }
    bindsym Mod1+Tab focus next
    bindsym Mod1+Shift+Tab focus prev
    bindsym Mod1+F4 kill
    bindsym Mod4+Return exec foot
    bindsym XF86AudioRaiseVolume exec wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+
    bindsym XF86AudioLowerVolume exec wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
    bindsym XF86AudioMute exec wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
    for_window [app_id="pavucontrol"] floating enable
    for_window [app_id="blueman"] floating enable
    exec installer-gui >/tmp/installer-gui.log 2>&1
  '';
in
{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = false; # public download: free software only
  networking.networkmanager.enable = true;

  # --- Kiosk session: greetd logs the live user straight into sway ---
  programs.sway = {
    enable = true;
    # also start on machines (and VMs) without hardware rendering
    extraSessionCommands = "export WLR_RENDERER_ALLOW_SOFTWARE=1";
  };
  services.greetd = {
    enable = true;
    settings = rec {
      initial_session = {
        command = "sway --unsupported-gpu --config ${swayConfig}";
        user = "nixos";
      };
      default_session = initial_session; # again, if sway is ever closed
    };
  };

  # --- While it installs: browser, music, Bluetooth ---
  # Bluetooth is also how Chromium talks to a phone for passkey sign-in
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };
  services.blueman.enable = true;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };
  environment.sessionVariables.BROWSER = "installer-browser";
  xdg.mime.defaultApplications = lib.genAttrs
    [ "x-scheme-handler/http" "x-scheme-handler/https" "text/html" ]
    (_: "installer-browser.desktop");

  # --- Unfree extras, downloaded at run time (never part of the image) ---
  # Evaluated from the same nixpkgs as the image, so Chromium itself is
  # reused from the image and only the Widevine library and wrapper are new.
  systemd.services.installer-extras = {
    description = "Download Widevine (Chromium) and Claude Code";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = [ config.nix.package pkgs.git ];
    environment.HOME = "/root";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure"; # no network yet: try again
      RestartSec = 20;
    };
    script = ''
      mkdir -p ${extras}
      build() {
        nix build --impure --out-link "${extras}/$1" --expr \
          "with import ${inputs.nixpkgs} { config.allowUnfree = true; }; $2"
      }
      build claude claude-code
      build chromium 'chromium.override { enableWideVine = true; }'
    '';
  };

  environment.systemPackages = [
    install-nixos
    (pkgs.writeShellApplication {
      name = "resume-nixos";
      runtimeInputs = [ install-nixos ];
      text = ''exec install-nixos --resume "$@"'';
    })
    gui
    browser
    browserDesktop
    claude
    pkgs.chromium
    pkgs.cage # SSO login from the console installer
    pkgs.git
    pkgs.foot
    pkgs.pavucontrol
    pkgs.wireplumber # wpctl (volume keys)
    pkgs.xdg-utils
    pkgs.adwaita-icon-theme
  ];
  hardware.graphics.enable = true;
  fonts.fontconfig.enable = lib.mkForce true; # the minimal profile turns it off
  fonts.enableDefaultPackages = true;

  # Shown on the consoles (Ctrl+Alt+F2) next to the graphical installer
  services.getty.helpLine = lib.mkAfter ''

    The graphical installer runs on the first screen (Ctrl+Alt+F1).
    Without it: install-nixos   (wifi: nmtui)
  '';
}
