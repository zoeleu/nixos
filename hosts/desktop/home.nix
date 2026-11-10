# zoe's desktop-only apps (shared parts are in home/common.nix)
{ pkgs, ... }:

let
  # REA (npx rea-agents) only accepts Ghidra 12.1.x (verified with 12.1.4) and
  # rejects nixpkgs' 12.2, so pin the official 12.1.4 release. Drop this
  # override once REA supports the Ghidra that nixpkgs ships.
  ghidra = pkgs.ghidra-bin.overrideAttrs {
    version = "12.1.4";
    versiondate = "20260921";
    src = pkgs.fetchzip {
      url = "https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.1.4_build/ghidra_12.1.4_PUBLIC_20260921.zip";
      hash = "sha256-ZD4Vs1i7BMvrneAbAiOc7F9iBj64Rbom+PaVO//TzK8=";
    };
  };
  # REA wants the extracted release root, not the `ghidra` launcher in bin/.
  ghidraInstallDir = "${ghidra}/lib/ghidra";
in
{
  programs.vscode = {
    enable = true;
    package = pkgs.vscode; # Microsoft's build
  };

  home.packages = with pkgs; [
    (discord.override { withVencord = true; })
    spotify
    ghidra
    jdk21 # `java` on PATH: REA runs Ghidra headless and needs a full JDK 21+
  ];

  # Same two places as SSH_AUTH_SOCK in home/common.nix: login shells and
  # systemd user services, which is where the agents' MCP servers start from.
  home.sessionVariables.GHIDRA_INSTALL_DIR = ghidraInstallDir;
  systemd.user.sessionVariables.GHIDRA_INSTALL_DIR = ghidraInstallDir;
}
