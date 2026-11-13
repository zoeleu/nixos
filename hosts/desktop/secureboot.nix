# Secure Boot with Lanzaboote: this machine signs its own boot files (boot
# manager, and a stub binding kernel + initrd + command line) every time a
# generation is installed. The key never leaves it, except encrypted in
# secrets/secureboot.yaml. Firmware steps and recovery: ./secureboot.md
{ inputs, lib, pkgs, ciBuild ? false, ... }:
let
  # Interpolate into a store-path string: Lanzaboote runs `toString` on
  # publicKeyFile, which on a bare Nix path yields an unreferenced
  # flake-source path that isn't copied into /nix/store or kept from GC.
  certificate = "${./secureboot/db.pem}";
  signingKey = "/var/lib/sbctl/keys/db/db.key";
in
{
  imports = [ inputs.lanzaboote.nixosModules.lanzaboote ];

  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.systemd-boot.editor = false;
  boot.lanzaboote = {
    enable = !ciBuild;
    pkiBundle = "/var/lib/sbctl";
    publicKeyFile = certificate;
    privateKeyFile = signingKey; # runtime path, never a Nix path literal
    allowUnsigned = false;
  };

  # NixOS passes an explicit LSM list; lockdown must be included in it.
  # Integrity mode still allows perf/tracing (confidentiality would not).
  security.lsm = [ "lockdown" ];
  boot.kernelParams = [ "lockdown=integrity" ];

  sops.secrets.secureboot-db-key = {
    sopsFile = ../../secrets/secureboot.yaml;
    key = "db_key";
    path = signingKey;
    mode = "0400";
  };
  systemd.tmpfiles.rules = [
    "d /var/lib/sbctl 0700 root root -"
    "d /var/lib/sbctl/keys 0700 root root -"
    "d /var/lib/sbctl/keys/db 0700 root root -"
  ];
  environment.systemPackages = [ pkgs.sbctl pkgs.sbsigntool ]; # sbctl status/verify, sbverify
}
