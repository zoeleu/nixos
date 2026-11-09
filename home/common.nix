# zoe's Home Manager config, shared by every machine
{ config, pkgs, lib, ... }:

let
  # SSH key used for signing commits; its private half lives in Bitwarden.
  signing-key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDASV5glPTSjwJmpiM9Cs2uU4+rke4vJxWXSZHhkjj/x3nTkE847O8QxJV63J92WlzbP9PDwp4/YYIMPQGE1NGFAKjgFBLKPJ7Ej7utvaiOxtc/4cut7BSNUOcCvzId+rw2SmtZGoxmJ6nZUu7HLK5ADxcgRNyL9DFUChyYinIBVujXPbFG94dKF7gELPxXlcXgi1nQkYmquDDO25ZSyu3FcynFbHBH3Iq2ke2t6Eek+gtWpddoF1MDzVRUDTBgywqozgWe24MtH7dHJSY12pMZxUc70NOvP5IV3svA1C+1Wj8vyCRMuqLypeMMtURbWzwD4JWZC9ZQHHBrYGgeMx2QxAgFFhRd6OCyGRh3WPCqIkMg+Hjdcg1GSvXhePYrBCNA7miNXjzb2IVvVrL8KvLl6C/eJK/zREZitUgOcGFbObYAybLAJ+2RQfMjCkrCa34xluzvm8lOLFpW9tQWW+6//hFvRvRlo8+6naXYu198eTdC9inw9XcUjHqg0mvCVJc=";

  # Bitwarden desktop's SSH agent (enable it in Bitwarden:
  # Settings > Enable SSH agent). Keys stay in the vault.
  bitwarden-agent = "${config.home.homeDirectory}/.bitwarden-ssh-agent.sock";
in
{
  home.username = "zoe";
  home.homeDirectory = "/home/zoe";

  home.packages = [ pkgs.bitwarden-desktop ];

  # Start Bitwarden at login so the SSH agent is available
  xdg.configFile."autostart/bitwarden.desktop".source =
    "${pkgs.bitwarden-desktop}/share/applications/bitwarden.desktop";

  # Every program (terminal, Plasma, git, ssh-keygen) uses Bitwarden's agent
  home.sessionVariables.SSH_AUTH_SOCK = bitwarden-agent;
  systemd.user.sessionVariables.SSH_AUTH_SOCK = bitwarden-agent;

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings."*" = {
      IdentityAgent = bitwarden-agent;
      ForwardAgent = "no";
      AddKeysToAgent = "no";
    };
  };

  programs.git = {
    enable = true;
    settings = {
      user = {
        email = "git@zoe.dev.br";
        name = "Zoe Leullier";
        # "key::" = literal public key; ssh-keygen signs via the agent
        signingKey = "key::${signing-key}";
      };
      gpg.format = "ssh";
      commit.gpgsign = true;
      safe.directory = "/etc/nixos";
    };
  };

  # fish is the login shell (set in modules/common.nix); let HM manage it so
  # session variables above apply in fish too
  programs.fish = {
    enable = true;
    interactiveShellInit = "set -g fish_greeting"; # no greeting
  };
}
