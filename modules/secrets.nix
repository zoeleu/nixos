# Secrets from secrets/*.yaml, encrypted with sops (see .sops.yaml).
# Each machine decrypts them at boot/activation with its SSH host key
# (/etc/ssh/ssh_host_ed25519_key), so nothing secret is in the Nix store or
# in this public repo.
#
# Edit: SOPS_AGE_KEY=<Bitwarden "sops: age key"> sops secrets/<file>.yaml
{ config, inputs, ... }:

{
  imports = [ inputs.sops-nix.nixosModules.sops ];

  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  # Pull token for the private Attic cache (https://cache.zoe.dev.br/nixos),
  # in netrc format, readable by root (the nix daemon) only
  sops.secrets.attic-netrc = {
    sopsFile = ../secrets/attic.yaml;
    key = "netrc";
    mode = "0400";
  };
  nix.settings.netrc-file = config.sops.secrets.attic-netrc.path;
}
