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
| `desktop` | AMD RX 9060 XT PC, Plasma, Incus for AI-agent VMs (config ready, not installed yet) |

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

A folder in `hosts/` only becomes a machine once it has a
`hardware-configuration.nix` (generated on the real machine), so a host can
be prepared before it's installed.

1. Install NixOS with the graphical installer: tick "Encrypt system", ext4,
   user `zoe`, allow unfree software. Desktop choice doesn't matter.
2. After the first boot (as zoe, online):
   ```bash
   sudo mv /etc/nixos /etc/nixos.installer
   sudo git clone https://github.com/zoeleu/nixos /etc/nixos
   sudo cp /etc/nixos.installer/hardware-configuration.nix /etc/nixos/hosts/<hostname>/
   grep -n 'luks' /etc/nixos.installer/configuration.nix
   ```
   The installer may put LUKS lines (e.g. for the encrypted swap) in its
   `configuration.nix` instead of `hardware-configuration.nix`; copy any
   `boot.initrd.luks.devices...` line it shows into the host's
   `default.nix` (the deck has its swap line there too).
3. New host only: create `hosts/<hostname>/default.nix` (boot loader,
   desktop, SSH policy, `home-manager.users.zoe.home.stateVersion`,
   `system.stateVersion`; see the existing hosts).
4. `cd /etc/nixos && sudo git add -A` (flakes only see tracked files), then
   `sudo nixos-rebuild boot --flake /etc/nixos#<hostname>` and reboot.
5. Commit and push the hardware config; CI starts building the host.

## CI / binary cache

`.github/workflows/build.yml` builds every host on each push and weekly
(with `nix flake update`):

1. Each slow package (`ci.heavyPackages`: kernel, Mesa, PipeWire from
   `modules/ci.nix`, plus per-host extras) builds in its own job, all on
   separate runners at the same time.
2. Then each host's full system builds, downloading those from the cache.

Every job pushes each compiled package to Cachix as soon as it finishes,
and pushes whatever finished even if the build fails. Unfree packages
(Steam, claude-code, ...) and anything depending on them are never pushed,
since the cache is public.

To add a slow package to the parallel jobs, add it to `ci.heavyPackages` in
the host's `default.nix`.

Cache: https://zoeleu.cachix.org. Setup: repo variable `CACHIX_CACHE` (cache name) and secret
`CACHIX_AUTH_TOKEN`, then add the cache's URL and public key in
`modules/common.nix`.
