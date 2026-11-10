# Prints (as `trace: UNFREE <name>` on stderr) every package of a host that
# must never be pushed to the public cache:
#   - unfree packages in the system closure (nixpkgs' own license check), and
#   - Jovian packages that are binary-only and have no license (e.g. Valve's
#     jupiter-dock-updater-bin, firmware blobs).
# Policy (Zoe's call): anything built from public source may be pushed, even
# without a license field. Sources themselves (downloaded archives, e.g.
# Steam's) are excluded separately by ci/push-built.sh.
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

  # Binary-only: marked as such by nixpkgs' sourceProvenance, a "-bin"
  # package, or firmware.
  isBinaryOnly = name: pkg:
    lib.any (p: p.isSource or true == false) (pkg.meta.sourceProvenance or [ ])
    || lib.hasSuffix "-bin" name
    || lib.hasInfix "firmware" name;

  jovian = system.pkgs.jovianPackages or { };
  blocked = lib.filter (name:
    let
      pkg = builtins.tryEval jovian.${name};
      isDrv = pkg.success && lib.isDerivation pkg.value;
    in
    isDrv && !(pkg.value ? meta.license) && isBinaryOnly name pkg.value
  ) (lib.attrNames jovian);
  traceBlocked = lib.foldl'
    (acc: name: builtins.trace "UNFREE ${lib.getName jovian.${name}}" acc)
    null
    blocked;
in
builtins.seq traceBlocked system.config.system.build.toplevel.drvPath
