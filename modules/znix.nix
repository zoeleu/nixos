# `znix`: work on the config checked out in /etc/nixos (see `znix help`).
# `os` manages what CI built and deployed; `znix` checks and applies local,
# uncommitted changes before they are pushed.
{ config, lib, pkgs, ... }:

let
  znix = pkgs.writeShellApplication {
    name = "znix";
    runtimeInputs = with pkgs; [ config.nix.package git nvd coreutils jq actionlint ];
    text = ''
      dir=''${ZNIX_DIR:-/etc/nixos}
      # Same file as `os rollback`: pauses automatic updates (modules/os-command.nix)
      hold=/var/lib/os-update-hold
      bold() { printf '\033[1m%s\033[0m\n' "$*"; }
      ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
      fail() { printf '\033[31m✗\033[0m %s\n' "$*"; }

      usage() {
        cat <<'USAGE'
      Usage: znix <command> [args]

      Test the config in /etc/nixos (override with ZNIX_DIR):
        check [HOST...]   evaluate every host (nixos + CI configurations), or only HOST
        dry [HOST]        what would be downloaded/compiled (default: this machine)
        build [HOST]      build the system and show what changes vs the running one
        vm [TEST...]      run the NixOS VM tests (default: all of them)
        lint              actionlint the CI workflows

      Apply it to this machine:
        test              activate until reboot (boot menu unchanged)
        switch [--hold]   activate and make it the default boot entry
                          --hold: also pause automatic updates so CI's build
                          doesn't replace it (undo: os resume / os update)
        boot              make it the default for the next boot only
      USAGE
      }

      # Nix only sees files git tracks; an untracked module is silently missing
      warn_untracked() {
        local untracked
        untracked=$(git -C "$dir" ls-files --others --exclude-standard)
        if [ -n "$untracked" ]; then
          echo "warning: untracked files are invisible to nix (git add them):" >&2
          printf '  %s\n' "$untracked" >&2
        fi
      }

      attrs() { nix eval --json "$dir#$1" --apply builtins.attrNames | jq -r '.[]'; }

      cmd=''${1:-help}
      shift || true
      case "$cmd" in
        check)
          warn_untracked
          status=0
          found=0
          for set in nixosConfigurations ciConfigurations; do
            mapfile -t hosts < <(attrs "$set")
            for host in "''${hosts[@]}"; do
              # with arguments, only the hosts named
              if [ "$#" -gt 0 ] && ! printf '%s\n' "$@" | grep -qx "$host"; then continue; fi
              found=1
              if out=$(nix eval --raw "$dir#$set.$host.config.system.build.toplevel.drvPath" 2>&1); then
                ok "$set.$host"
              else
                fail "$set.$host"; echo "$out" | tail -20; status=1
              fi
            done
          done
          [ "$found" = 1 ] || { echo "No such host: $*" >&2; exit 2; }
          exit "$status"
          ;;
        dry)
          warn_untracked
          nix build --dry-run "$dir#nixosConfigurations.''${1:-$(hostname)}.config.system.build.toplevel"
          ;;
        build)
          warn_untracked
          host=''${1:-$(hostname)}
          out=$(nix build --no-link --print-out-paths -L "$dir#nixosConfigurations.$host.config.system.build.toplevel")
          bold "$out"
          if [ "$host" = "$(hostname)" ]; then nvd diff /run/current-system "$out"; fi
          ;;
        vm)
          if [ "$#" -gt 0 ]; then tests=("$@"); else mapfile -t tests < <(attrs checks.x86_64-linux); fi
          for t in "''${tests[@]}"; do
            bold "VM test: $t"
            nix build -L --no-link "$dir#checks.x86_64-linux.$t"
          done
          ;;
        lint)
          actionlint -ignore SC2016 "$dir"/.github/workflows/*.yml
          ;;
        test|switch|boot)
          warn_untracked
          if [ "$cmd" = switch ] && [ "''${1:-}" = --hold ]; then
            sudo touch "$hold"
            echo "Automatic updates paused until: os resume (or os update)"
          fi
          sudo nixos-rebuild "$cmd" --flake "$dir"
          if [ "$cmd" != test ] && [ ! -e "$hold" ]; then
            echo "Note: the next automatic update replaces this with CI's build of main."
            echo "      Push the change, or use: znix switch --hold"
          fi
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
  environment.systemPackages = [ znix ];
}
