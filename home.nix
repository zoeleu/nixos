{ config, pkgs, lib, ... }:

let
  public-ssh-key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDASV5glPTSjwJmpiM9Cs2uU4+rke4vJxWXSZHhkjj/x3nTkE847O8QxJV63J92WlzbP9PDwp4/YYIMPQGE1NGFAKjgFBLKPJ7Ej7utvaiOxtc/4cut7BSNUOcCvzId+rw2SmtZGoxmJ6nZUu7HLK5ADxcgRNyL9DFUChyYinIBVujXPbFG94dKF7gELPxXlcXgi1nQkYmquDDO25ZSyu3FcynFbHBH3Iq2ke2t6Eek+gtWpddoF1MDzVRUDTBgywqozgWe24MtH7dHJSY12pMZxUc70NOvP5IV3svA1C+1Wj8vyCRMuqLypeMMtURbWzwD4JWZC9ZQHHBrYGgeMx2QxAgFFhRd6OCyGRh3WPCqIkMg+Hjdcg1GSvXhePYrBCNA7miNXjzb2IVvVrL8KvLl6C/eJK/zREZitUgOcGFbObYAybLAJ+2RQfMjCkrCa34xluzvm8lOLFpW9tQWW+6//hFvRvRlo8+6naXYu198eTdC9inw9XcUjHqg0mvCVJc=";
in
{
    # Home Manager needs a bit of information about you and the
    # paths it should manage.
    home.username = "zoe";
    home.homeDirectory = "/home/zoe";

    home.packages = [
      pkgs.fortune
      (pkgs.discord.override {
        withOpenASAR = true; # can do this here too
        withVencord = true;
      })
      (pkgs.prismlauncher.override {
        # Add binary required by some mod
        additionalPrograms = [ pkgs.ffmpeg ];

        # Change Java runtimes available to Prism Launcher
        jdks = [
          pkgs.graalvmPackages.graalvm-ce
          pkgs.zulu8
          pkgs.zulu17
          pkgs.zulu
        ];
      })
      pkgs.google-chrome
      pkgs.htop
      pkgs.chntpw
      pkgs.spotify
      pkgs.distroshelf

      pkgs.jetbrains.idea
    ];

    programs.git = {
      enable = true;
      settings = {
        user = {
          email = "git@zoe.dev.br";
          name = "Zoe Leullier";
          signingKey = public-ssh-key;
        };
        gpg = {
          format = "ssh";
        };
        "gpg \"ssh\"" = {
          program = "${lib.getExe' pkgs._1password-gui "op-ssh-sign"}";
        };
        commit = {
          gpgsign = true;
        };
        safe = {
          directory = "/etc/nixos";
        };
      };
    };

    programs.ssh = {
      enable = true;

      enableDefaultConfig = false;
      matchBlocks."*" = {
        forwardAgent = false;
        addKeysToAgent = "no";
        compression = false;
        serverAliveInterval = 0;
        serverAliveCountMax = 3;
        hashKnownHosts = false;
        userKnownHostsFile = "~/.ssh/known_hosts";
        controlMaster = "no";
        controlPath = "~/.ssh/master-%r@%n:%p";
        controlPersist = "no";
      };

      extraConfig = ''
        Host *
            IdentityAgent "~/.1password/agent.sock"
      '';
    };

    programs.vscode = {
      enable = true;
    };

    services.mpris-proxy.enable = true;

    home.file."/home/zoe/.config/fish/conf.d/no-hello.fish" = {
      text = "set -g fish_greeting";
      enable = true;
    };

    # This value determines the Home Manager release that your configuration is
    # compatible with. This helps avoid breakage when a new Home Manager release
    # introduces backwards incompatible changes.
    #
    # You should not change this value, even if you update Home Manager. If you do
    # want to update the value, then make sure to first check the Home Manager
    # release notes.
    home.stateVersion = "25.11"; # Please read the comment before changing.
}
