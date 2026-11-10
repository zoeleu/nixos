# zoe's desktop-only apps (shared parts are in home/common.nix)
{ pkgs, ... }:

{
  programs.vscode = {
    enable = true;
    package = pkgs.vscode; # Microsoft's build
  };

  home.packages = with pkgs; [
    (discord.override { withVencord = true; })
    spotify
  ];
}
