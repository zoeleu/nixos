# nixos

NixOS configuration for all my machines, as one flake.

```
flake.nix            # turns every folder in hosts/ into a machine
modules/common.nix   # system settings shared by all machines
home/common.nix      # zoe's Home Manager config shared by all machines
hosts/<name>/        # one folder per machine (hostname = folder name)
  default.nix
  hardware-configuration.nix
ci/                  # helpers for GitHub Actions
```

| Host | Machine |
|---|---|
| `deck` | Steam Deck (LCD) with [Jovian NixOS](https://github.com/Jovian-Experiments/Jovian-NixOS) |

Shared everywhere: fish, pt_BR formats, Tailscale, Bitwarden (also as SSH
agent and for signing git commits), Home Manager, claude-code.

## Usage

The repo lives in `/etc/nixos` on each machine.

```bash
sudo nixos-rebuild switch --flake /etc/nixos        # apply (picks config by hostname)
cd /etc/nixos && git pull && sudo nixos-rebuild switch --flake .   # get CI's weekly update
```

Don't run `nix flake update` locally: CI does it weekly and only commits the
new `flake.lock` after every host built, so pulling it means downloading
instead of compiling.

## Bitwarden SSH agent

Vault server: https://vw.zoe.dev.br (self-hosted Vaultwarden; pick
"Self-hosted" on the Bitwarden login screen).

In Bitwarden: Settings > Enable SSH agent, and store the SSH keys in the
vault. Bitwarden starts at login; `ssh`, `git` and commit signing use its
socket (`~/.bitwarden-ssh-agent.sock`).

## Adding a machine

1. Install NixOS on it normally.
2. Clone this repo to `/etc/nixos` (move the generated files aside first).
3. Create `hosts/<hostname>/` with the generated `hardware-configuration.nix`
   and a `default.nix` with the machine's boot loader, desktop, SSH policy,
   `home-manager.users.zoe.home.stateVersion` and `system.stateVersion`
   (see `hosts/deck/default.nix`).
4. `git add` it (flakes only see tracked files), then
   `sudo nixos-rebuild switch --flake /etc/nixos#<hostname>`.

CI picks up new hosts automatically.

Planned `desktop`: fresh install with disk encryption (LUKS), auto-login
into zoe, key-only SSH.

## CI / binary cache

`.github/workflows/build.yml` builds every host on each push and weekly
(with `nix flake update`), and pushes what it compiled to Cachix. Unfree
packages (Steam, claude-code, ...) and anything depending on them are never
pushed, since the cache is public.

Cache: https://zoeleu.cachix.org. Setup: repo variable `CACHIX_CACHE` (cache name) and secret
`CACHIX_AUTH_TOKEN`, then add the cache's URL and public key in
`modules/common.nix`.
