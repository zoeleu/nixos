# Plasma's look, the same for every user that imports this (zoe everywhere,
# `deck` on the Steam Deck): Breeze Dark, the accent colour and wallpaper of
# pkgs/artwork.nix. Only these settings are managed (plasma-manager without
# overrideConfig): everything else changed in System Settings is kept, and
# these are re-applied only when they change here.
{ pkgs, ... }:

let
  artwork = pkgs.callPackage ../pkgs/artwork.nix { };
in
{
  programs.plasma = {
    enable = true;
    workspace = {
      lookAndFeel = "org.kde.breezedark.desktop";
      wallpaper = artwork.wallpaper;
    };
    kscreenlocker.appearance.wallpaper = artwork.wallpaper;
    configFile.kdeglobals.General = {
      AccentColor = artwork.accentRgb;
      accentColorFromWallpaper = false;
    };
    # After the look-and-feel (priority 1), which resets the accent colour
    startup.startupScript.accent-colour = {
      text = "plasma-apply-colorscheme --accent-color '${artwork.accent}' BreezeDark";
      priority = 2;
    };
  };
}
