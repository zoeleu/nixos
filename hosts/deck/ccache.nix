# Compile Jovian's kernel and Mesa forks through ccache, so CI can reuse
# object files between versions (e.g. a kernel bump recompiles only what
# changed). CI keeps the ccache folder between runs with actions/cache.
#
# Only packages that cache.nixos.org doesn't have are wrapped: wrapping a
# package changes its hash, so wrapping anything from nixpkgs would make it
# miss the official cache and get rebuilt.
#
# The cache folder /var/cache/ccache is visible inside the Nix sandbox only
# where `extra-sandbox-paths` allows it (CI does). Anywhere else, e.g. if the
# Deck compiles one of these itself, ccache is skipped and the normal
# compiler runs.
{ lib, ... }:

{
  nixpkgs.overlays = lib.mkAfter [
    (final: prev: {
      ccacheWrapper = prev.ccacheWrapper.override {
        extraConfig = ''
          export CCACHE_COMPRESS=1
          export CCACHE_SLOPPINESS=random_seed
          export CCACHE_DIR=/var/cache/ccache
          export CCACHE_UMASK=007
          export CCACHE_MAXSIZE=4G
          if [ ! -w "$CCACHE_DIR" ]; then
            export CCACHE_DISABLE=1 # no cache folder here: plain compiler
          fi
        '';
      };

      jovianPackages = prev.jovianPackages.overrideScope (jfinal: jprev: {
        linux = jprev.linux.override { stdenv = final.ccacheStdenv; };
        mesa-radeonsi = jprev.mesa-radeonsi.override { stdenv = final.ccacheStdenv; };
        mesa-radv = jprev.mesa-radv.override { stdenv = final.ccacheStdenv; };
      });
    })
  ];
}
