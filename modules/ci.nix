# Packages CI builds in their own parallel jobs before the full system,
# so the slowest compiles run side by side instead of sharing one runner.
# Hosts add their own slow packages to `ci.heavyPackages`. Packages already
# on cache.nixos.org just download, so listing a package costs little.
{ config, lib, ... }:

{
  options.ci.heavyPackages = lib.mkOption {
    type = lib.types.attrsOf lib.types.package;
    default = { };
    description = "Slow-to-build packages that CI builds in parallel jobs (name -> package).";
  };

  config.ci.heavyPackages = {
    kernel = config.boot.kernelPackages.kernel;
    graphics = config.hardware.graphics.package;
    pipewire = config.services.pipewire.package;
    wireplumber = config.services.pipewire.wireplumber.package;
  }
  // lib.optionalAttrs config.hardware.graphics.enable32Bit {
    graphics-32bit = config.hardware.graphics.package32;
  }
  // lib.listToAttrs (lib.imap0 (i: pkg: {
    name = "graphics-extra-${toString i}";
    value = pkg;
  }) config.hardware.graphics.extraPackages);
}
