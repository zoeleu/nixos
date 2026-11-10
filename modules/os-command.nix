# `os`: one command for the things you do to this system (see `os help`).
# Machines update themselves (modules/auto-upgrade.nix); this shows what
# happened, forces it, or undoes it.
{ config, lib, pkgs, ... }:

let
  hold = "/var/lib/os-update-hold";
  # "switch" (desktop) or "boot" (Deck: applies at the next boot)
  operation = config.system.autoUpgrade.operation;
  os = pkgs.writeShellApplication {
    name = "os";
    runtimeInputs = with pkgs; [ nvd coreutils systemd gnugrep ];
    text = ''
      hold=${hold}
      bold() { printf '\033[1m%s\033[0m\n' "$*"; }

      usage() {
        cat <<'USAGE'
      Usage: os <command>

        status        version, last and next automatic update (default)
        update        update now (and resume automatic updates)
        diff          packages changed by the last update
        rollback      go back to the previous generation and pause updates
        resume        resume automatic updates after a rollback
        generations   list installed generations
        clean [AGE]   delete generations older than AGE (default 14d) and free space
        test [DIR]    try the config in DIR (default ~/configuration) until reboot
      USAGE
      }

      case "''${1:-status}" in
        status)
          bold "$(hostname): NixOS $(nixos-version)"
          echo "Config:      $(nixos-version --configuration-revision 2>/dev/null || echo "not from a commit")"
          echo "Generation:  $(basename "$(readlink /nix/var/nix/profiles/system)" | grep -o '[0-9]\+')"
          if [ "$(readlink -f /nix/var/nix/profiles/system)" != "$(readlink -f /run/current-system)" ]; then
            echo "Restart:     an update is installed and starts at the next boot"
          elif [ "$(readlink -f /run/booted-system/kernel)" != "$(readlink -f /run/current-system/kernel)" ]; then
            echo "Restart:     needed for the new kernel"
          fi
          if [ -e "$hold" ]; then
            echo "Updates:     PAUSED since $(date -r "$hold" '+%F %R') (os resume)"
          else
            echo "Last update: $(systemctl show nixos-upgrade -P ExecMainExitTimestamp) ($(systemctl show nixos-upgrade -P Result))"
            echo "Next check:  $(systemctl show nixos-upgrade.timer -P NextElapseUSecRealtime)"
          fi
          ;;
        update)
          sudo rm -f "$hold"
          journalctl -u nixos-upgrade -f -n 0 -o cat &
          log=$!
          trap 'kill "$log" 2>/dev/null || true' EXIT
          sudo systemctl start nixos-upgrade
          ${lib.optionalString (operation == "boot") ''echo "Installed; it starts at the next boot."''}
          ;;
        diff)
          mapfile -t gens < <(find /nix/var/nix/profiles -maxdepth 1 -name 'system-*-link' | sort -V | tail -2)
          [ "''${#gens[@]}" -eq 2 ] || { echo "Only one generation installed."; exit 0; }
          nvd diff "''${gens[@]}"
          ;;
        rollback)
          # Without the hold the next automatic update would undo the rollback
          sudo touch "$hold"
          sudo nixos-rebuild ${operation} --rollback
          echo "Automatic updates are paused. Fix the config, then: os update"
          ;;
        resume)
          sudo rm -f "$hold"
          echo "Automatic updates resumed."
          ;;
        generations)
          nixos-rebuild list-generations
          ;;
        clean)
          sudo nix-collect-garbage --delete-older-than "''${2:-14d}"
          ;;
        test)
          sudo nixos-rebuild test --flake "''${2:-$HOME/configuration}"
          ;;
        help|-h|--help)
          usage
          ;;
        *)
          usage >&2
          exit 2
          ;;
      esac
    '';
  };
in
{
  environment.systemPackages = [ os ];

  # `os rollback` pauses automatic updates until `os update` / `os resume`
  systemd.services.nixos-upgrade.unitConfig.ConditionPathExists = "!${hold}";

  # Housekeeping: old generations go after two weeks, and the boot menu
  # keeps the last ten so /boot never fills up
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  boot.loader.systemd-boot.configurationLimit = lib.mkDefault 10;
}
