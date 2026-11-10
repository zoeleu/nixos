# The look of the system outside Plasma (Plasma itself: home/plasma.nix):
# boot splash theme, quiet boot and fastfetch, in the colours of
# pkgs/artwork.nix. The boot splash is only themed here; each host turns it
# on (`boot.plymouth.enable`) because it depends on how its disk is unlocked.
{ config, lib, pkgs, ... }:

let
  artwork = pkgs.callPackage ../pkgs/artwork.nix { };
  rgb = "38;2;" + lib.replaceStrings [ "," ] [ ";" ] artwork.accentRgb; # ANSI truecolor
in
{
  boot.plymouth = {
    theme = "breeze"; # asks for the disk passphrase itself
    logo = artwork.logo;
  };
  # No kernel/systemd messages over the splash (Esc shows them)
  boot.kernelParams = lib.mkIf config.boot.plymouth.enable [ "quiet" ];
  boot.consoleLogLevel = lib.mkIf config.boot.plymouth.enable 3;

  environment.systemPackages = [ pkgs.fastfetch ];
  environment.etc."xdg/fastfetch/config.jsonc".text = builtins.toJSON {
    logo = {
      type = "builtin";
      source = "nixos";
      color = { "1" = rgb; "2" = "38;2;95;220;195"; };
    };
    display.color = { keys = rgb; title = rgb; };
  };
}
