# Every machine updates itself from GitHub. It follows the `built` branch,
# which CI moves only after every host built and its packages are in the
# Attic cache (.github/workflows/build.yml, job "publish"). So:
#   push to main -> CI builds -> `built` moves -> machines update within ~15 min
# and a push that doesn't build never reaches a machine.
{ lib, ... }:

{
  system.autoUpgrade = {
    enable = true;
    flake = "github:zoeleu/nixos/built"; # picks nixosConfigurations.<hostname>
    dates = "*:0/15"; # check every 15 minutes
    randomizedDelaySec = "2min";
    persistent = true; # catch up after being off
    # switch = apply now; hosts can use "boot" (apply at next boot) instead
    operation = lib.mkDefault "switch";
    allowReboot = false;
  };
}
