# Prints (as `trace: UNFREE <name>` on stderr) every unfree package in a
# host's system closure, so CI can keep them out of the public cache.
# Usage: HOST=deck nix eval --impure --raw --file ci/unfree-names.nix
let
  flake = builtins.getFlake (toString ../.);
  lib = flake.inputs.nixpkgs.lib;
  host = builtins.getEnv "HOST";
  system = flake.nixosConfigurations.${host}.extendModules {
    modules = [{
      nixpkgs.config.allowUnfree = lib.mkForce false;
      nixpkgs.config.allowUnfreePredicate =
        lib.mkForce (pkg: builtins.trace "UNFREE ${lib.getName pkg}" true);
    }];
  };
in
system.config.system.build.toplevel.drvPath
