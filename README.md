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
| `desktop` | AMD RX 9060 XT PC, Plasma, Incus for AI-agent VMs; installs from the installer ISO (not installed yet) |

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

## Installing a machine (installer ISO)

Hosts with a `disko.nix` (disk layout) install from the installer ISO,
published by `.github/workflows/iso.yml` at
https://nix.zoe.dev.br/nixos-zoe-installer.iso (vps-main, via Tailscale):

1. Write the ISO to a USB stick (or put it on Ventoy) and boot it.
2. Connect to the internet (Ethernet works automatically; wifi: `nmtui`).
3. Run `install-nixos`: pick the host and the disk to **erase**, then log in
   to Vaultwarden with **SSO** (a full-screen Firefox opens) or your
   **personal API key** (web vault: Account settings
   > Security > Keys), then your master password. It reads the vault item
   `nixos: <host>` (password = zoe's password, hidden field
   `disk passphrase` = disk encryption passphrase); if missing it asks and
   offers to save them. Skip the vault to just type them. Then wait.
4. After the first boot, sign in to Bitwarden and enable its SSH agent, then
   as zoe: `cd /etc/nixos && git commit -m "<host>:
   hardware config" && git push` (the installer generated
   `hardware-configuration.nix` and `disk.nix` for the host, and made
   `/etc/nixos` zoe's, pushing over SSH).

The ISO clones the latest config from GitHub, so it only needs rebuilding
when `installer/` changes. Claude Code isn't on it (public download,
unfree); if needed there: `NIXPKGS_ALLOW_UNFREE=1 nix run --impure nixpkgs#claude-code`.

## Adding a machine without the ISO

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
