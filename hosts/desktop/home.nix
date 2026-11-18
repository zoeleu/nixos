# zoe's desktop-only apps (shared parts are in home/common.nix)
{ config, lib, pkgs, osConfig, ... }:

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

  # REA (reverse engineering) for every agent, with Ghidra passed directly
  # instead of through the session environment
  rea = {
    command = "npx";
    args = [ "-y" "rea-agents@6.8.0" "mcp" ];
    env.GHIDRA_INSTALL_DIR = ghidraInstallDir;
  };

  # Claude Code signs in with the long-lived token from `claude setup-token`,
  # kept in sops (secrets/claude-code.yaml, hosts/desktop/default.nix) instead
  # of in ~/.claude/settings.json. Every `claude` here is this one, T3 Code's
  # included, so they all find the token.
  oauthToken = osConfig.sops.secrets.claude-code-oauth-token.path;
  claude-with-token = pkgs.writeShellScript "claude" ''
    if [ -z "''${CLAUDE_CODE_OAUTH_TOKEN-}" ] && [ -r ${oauthToken} ]; then
      CLAUDE_CODE_OAUTH_TOKEN=$(< ${oauthToken})
      export CLAUDE_CODE_OAUTH_TOKEN
    fi
    exec ${pkgs.claude-code}/bin/claude "$@"
  '';
  claude-code = pkgs.symlinkJoin {
    pname = "claude-code";
    inherit (pkgs.claude-code) version meta;
    paths = [ pkgs.claude-code ];
    postBuild = ''
      rm $out/bin/claude
      ln -s ${claude-with-token} $out/bin/claude
    '';
  };
in
{
  # Coding agents (Claude Code and Pi are in home/common.nix, and so are the
  # MCP servers every machine gets). The codex package is the overlay's
  # (overlays/codex.nix), as everywhere else.
  programs.mcp.servers = { inherit rea; };
  programs.claude-code.package = claude-code;
  programs.codex = {
    enable = true;
    mutableSettings = true;
    enableMcpIntegration = true;
    # Codex's own timeouts for REA (Ghidra analyses are slow). Codex takes
    # a server from here whole instead of merging it with programs.mcp's.
    settings.mcp_servers.rea = rea // {
      startup_timeout_sec = 30;
      tool_timeout_sec = 450;
    };
  };
  programs.opencode = {
    enable = true;
    mutableSettings = true;
    enableMcpIntegration = true;
  };
  programs.antigravity = {
    enable = true; # Google's agent IDE (VS Code based)
    package = pkgs.antigravity-ide; # nixpkgs renamed it
  };
  programs.antigravity-cli = {
    enable = true;
    mutableSettings = true;
    enableMcpIntegration = true;
  };
  # With mutableSettings OpenCode finds Home Manager's config through
  # OPENCODE_CONFIG, which the module sets for shells only; give it to apps
  # started outside a shell too (T3 Code, the desktop), like SSH_AUTH_SOCK in
  # home/common.nix.
  systemd.user.sessionVariables.OPENCODE_CONFIG =
    "${config.xdg.configHome}/opencode/home-manager.json";

  programs.vscode = {
    enable = true;
    package = pkgs.vscode; # Microsoft's build
  };

  # The session logs in by itself after the disk passphrase and sudo asks
  # for nothing, so the lock screen is the only gate while the PC is on.
  # These are Plasma's defaults, pinned so a stray click can't turn them off.
  programs.plasma.kscreenlocker = {
    autoLock = true;
    timeout = 5; # minutes idle
    lockOnResume = true;
    passwordRequired = true;
    passwordRequiredDelay = 0; # no grace period after the screen locks
  };

  # Tailscale's own tray icon (connect/disconnect, exit nodes); it can only
  # change settings because zoe is the operator (hosts/desktop/default.nix)
  services.tailscale-systray.enable = true;

  home.packages = with pkgs; [
    (discord.override { withVencord = true; })
    spotify
    # T3 Code (GUI for coding agents) driving Claude Code and Codex
    (t3code.override {
      enableClaude = true;
      claude-code = config.programs.claude-code.finalPackage; # the one above
    })
    ghidra
    jdk21 # `java` on PATH: REA runs Ghidra headless and needs a full JDK 21+
  ];

  # For running Ghidra/REA by hand; the MCP server gets it from `rea` above
  home.sessionVariables.GHIDRA_INSTALL_DIR = ghidraInstallDir;
}
