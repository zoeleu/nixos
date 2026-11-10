# Prints (as `trace: UNFREE <name>` on stderr) every package of a host that
# must never be pushed to the public cache:
#   - unfree packages in the system closure (nixpkgs' own license check), and
#   - Jovian packages without a license: no license means redistribution
#     isn't granted (e.g. Valve's jupiter-dock-updater-bin).
# Sources (downloaded archives) are excluded separately by ci/push-built.sh.
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

  # Jovian packages with no meta.license, except ones whose upstream license
  # was checked by hand. Only add a package here after checking its source
  # repo's license.
  knownOpenSource = [
    "mesa-radv"             # Mesa (Valve's fork, RADV): MIT
    "mesa-radeonsi"         # Mesa (Valve's fork, radeonsi): MIT
    "scx-scheds"            # sched-ext/scx: GPL-2.0
  ];
  jovian = system.pkgs.jovianPackages or { };
  unlicensed = lib.filter (name:
    let
      pkg = builtins.tryEval jovian.${name};
      isDrv = pkg.success && lib.isDerivation pkg.value;
    in
    isDrv && !(pkg.value ? meta.license) && !(lib.elem name knownOpenSource)
  ) (lib.attrNames jovian);
  traceUnlicensed = lib.foldl'
    (acc: name: builtins.trace "UNFREE ${lib.getName jovian.${name}}" acc)
    null
    unlicensed;
in
builtins.seq traceUnlicensed system.config.system.build.toplevel.drvPath
