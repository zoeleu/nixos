# nixos

NixOS configuration for all my machines, as one flake.

```
flake.nix            # turns every folder in hosts/ into a machine
modules/common.nix   # system settings shared by all machines
modules/secrets.nix  # sops-nix secrets (encrypted in secrets/, see .sops.yaml)
home/common.nix      # zoe's Home Manager config shared by all machines
hosts/<name>/        # one folder per machine (hostname = folder name)
  default.nix
  hardware-configuration.nix
.github/              # CI workflows (build, installer ISO) and shared actions
```

| Host | Machine |
|---|---|
| `deck` | Steam Deck (LCD) with [Jovian NixOS](https://github.com/Jovian-Experiments/Jovian-NixOS) |
| `desktop` | AMD RX 9060 XT PC, Plasma, Incus for AI-agent VMs; installs from the installer ISO (not installed yet) |

Shared everywhere: fish, pt_BR formats, Tailscale, Bitwarden (also as SSH
agent and for signing git commits), Home Manager, claude-code, and one look:
Breeze Dark with a teal accent, a teal NixOS snowflake on the boot splash and
wallpaper (`pkgs/artwork.nix` is the single place to change the colour).

## The `os` command

```bash
os              # version, config commit, last/next automatic update, restart needed?
os update       # update now
os diff         # what the last update changed
os rollback     # previous generation, and pause automatic updates
os resume       # un-pause them (os update does too)
os generations  # installed generations
os clean [14d]  # delete old generations, free space (also runs weekly)
os test [dir]   # try ~/configuration without committing, until reboot
```

## Unlocking the disks

- **desktop**: the boot splash asks for the disk passphrase (keyboard).
  `sudo` asks no password there.
- **deck**: an on-screen keyboard asks for it on the touchscreen (a USB
  keyboard still works); the splash appears after unlocking. To skip the
  passphrase entirely, enrol the TPM once, on the Deck:
  `sudo deck-tpm-enroll`. From then on it boots straight to Gaming Mode;
  the passphrase stays valid as fallback, and zoe's home stays encrypted
  with her login password. Undo: `sudo systemd-cryptenroll --wipe-slot=tpm2 <device>`.

## Usage

**Machines update themselves.** Push to `main` → CI builds every host and
fills the cache → CI moves the `built` branch → every machine picks it up
within ~15 minutes (`modules/auto-upgrade.nix`). The desktop applies updates
right away; the Deck at its next boot. A push that doesn't build never
reaches a machine.

Your working copy is `~/configuration`, cloned automatically at login
(pushes go over SSH with Bitwarden's agent). Edit, commit, push; that's it.

```bash
systemctl status nixos-upgrade                         # last auto-update
sudo systemctl start nixos-upgrade                     # update now
sudo nixos-rebuild switch --flake ~/configuration      # try uncommitted changes locally
```

Don't run `nix flake update` locally: CI does it weekly and only commits the
new `flake.lock` after every host built, so updates download instead of
compiling.

## Bitwarden SSH agent

Vault server: https://vw.zoe.dev.br (self-hosted Vaultwarden; pick
"Self-hosted" on the Bitwarden login screen).

In Bitwarden: Settings > Enable SSH agent, and store the SSH keys in the
vault. Bitwarden starts at login; `ssh`, `git` and commit signing use its
socket (`~/.bitwarden-ssh-agent.sock`).

## Secrets (sops-nix)

Secrets live encrypted in `secrets/*.yaml` and are decrypted on each machine
at boot with its SSH host key (`modules/secrets.nix`). `.sops.yaml` lists who
can decrypt: zoe's age key (Bitwarden `sops: age key`) and every machine.

```bash
SOPS_AGE_KEY=$(bw get password "sops: age key") sops secrets/attic.yaml   # edit
```

Currently: `secrets/attic.yaml` (pull token for the private Attic cache).
The installer adds new machines to `.sops.yaml` automatically.

## Installing a machine (installer ISO)

Hosts with a `disko.nix` (disk layout) install from the installer ISO,
published by `.github/workflows/iso.yml` at
https://nix.zoe.dev.br/nixos-zoe-installer.iso (vps-main, via Tailscale):

1. Write the ISO to a USB stick (or put it on Ventoy) and boot it. It
   starts the graphical installer; every window is a tab at the top
   (Alt+Tab switches).
2. Connect to the internet (Ethernet works automatically; wifi: pick the
   network in the window).
3. Choose what to do:
   - **Automatic**: shown when the disk recorded in `hosts/<host>/disk.nix`
     is in the machine (the desktop's SSD). One click, a 10-second
     countdown you can cancel, then it erases that disk and installs.
   - **Continue an interrupted installation**: resumes without erasing
     (after a reboot it first asks the disk passphrase to unlock it).
   - **Manual**: pick the host and the disk to **erase**, type its name.

   Then log in to Vaultwarden with **SSO** (a Chromium tab opens) or your
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

While it installs, the header bar has Chromium, Spotify, YouTube, a
terminal, Bluetooth, sound and network. The image is free software only, so
two things download after boot (the header says when they're ready):
Widevine (needed by Spotify) and Claude Code. **Ask Claude** opens Claude
Code with the installer's log; sign in with Google in the Chromium tab that
opens (a passkey on your phone works over Bluetooth). If a step fails, the
window offers **Troubleshoot with Claude** and **Resume**.

Without the GUI (Ctrl+Alt+F2): `install-nixos` on the console, as before.

### Resuming an interrupted installation (never rerun the erase flow)

The installer window offers this by itself ("Continue an interrupted
installation"); by hand:

Keep the existing LUKS root and EFI filesystems mounted at `/mnt` and
`/mnt/boot`. If the machine rebooted, inspect `lsblk -f` and open/mount the
**existing** filesystems; do not format them or run disko's destroy mode.

From the repaired installer, run:

```bash
sudo findmnt -R /mnt
sudo install-nixos --resume desktop   # or: sudo resume-nixos desktop
```

Resume requires the existing `/mnt/etc/nixos` checkout, generated
`hosts/desktop/hardware-configuration.nix` and `disk.nix`, and target SSH host
key. It verifies that both mounts belong to the configured disk and saves
the checkout under `/mnt/var/lib/nixos-install/` before SOPS changes. It
skips disk selection, disko, hardware generation and copying the checkout.
It reruns `nixos-install`, sets zoe's login password, fixes ownership and the
Git remote, and leaves rebooting to you. It never changes the existing LUKS
passphrase. Local hardware files and other local edits stay in place.

The installer now validates SOPS decryption and authenticated access to the
private cache **before partitioning**. The SOPS age key comes from the vault
or a hidden local prompt; on resume an already enrolled host key can also
work. The cache netrc comes from `secrets/attic.yaml` and stays in `/run`
until cleanup. A missing/invalid key or token stops the install instead of
silently attempting a large unauthenticated build. Vault login/session stays in a private directory under `/run` after a failed
build. `--resume` reuses it: an unlocked vault needs no prompt, and a locked
login needs only the master password. Success clears the installer-managed
session; reboot clears `/run`. A supplied `BW_SESSION` and CLI appdata path
are also reused, without logging out a borrowed login.

On an older ISO, apply the repair to the existing checkout first, then run
the repaired command with its declared tools (do not run the ISO's old
`install-nixos`):

```bash
sudo nix run /mnt/etc/nixos#install-nixos -- --resume desktop
```

ChatGPT and Codex are temporarily omitted from the desktop to unblock installation.
`overlays/tectonic.nix` still adds the system AWS-LC
library required by the pinned Rust Cargo hook; OpenSSL alone cannot
satisfy it. `nix build .#tectonic .#chatgpt` tests these packages even before
the desktop's generated hardware files are available. The lock file is
unchanged.

### Network boot (PXE) instead of a USB stick

The same installer is published at https://nix.zoe.dev.br/netboot/ (kernel +
initrd + iPXE script). On the home LAN the Deck answers PXE boot requests
(`hosts/deck/pxe.nix`: dnsmasq proxy-DHCP + TFTP; the TIM router keeps
handing out addresses) with an iPXE that loads it over HTTPS.

1. The Deck must be on and on the LAN (wifi or the dock's Ethernet).
2. On the PC (MSI): BIOS > Settings > Advanced > Integrated Peripherals >
   Network Stack: Enabled, IPv4 PXE Support: Enabled; Secure Boot off.
3. Boot menu (F11 on MSI) > the network card (UEFI: IPv4). The PC downloads
   ~2 GB into RAM, then: `install-nixos`.

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

The matrix uses `ciConfigurations`: installed hosts use their exact real
configuration. Before the desktop's generated hardware files are committed,
`hosts/desktop/ci.nix` supplies an explicit build-only profile with a
disposable tmpfs root and no bootloader. This profile is never exported in
`nixosConfigurations`, so the installer and auto-upgrade keep using real
hardware/disk files. Once those files are committed, CI automatically builds
the real desktop configuration instead.

1. Each slow package (`ci.heavyPackages`: kernel, Mesa, PipeWire from
   `modules/ci.nix`, plus per-host extras) builds in its own job, all on
   separate runners at the same time.
2. Then each host's full system builds, downloading those from the cache.
   Desktop also splits its CachyOS kernel and Claude Desktop into heavy
   jobs. It uses the same cache upload, ccache workflow
   and failure handling as the Deck; no separate desktop-only app job.
3. `built` advances only after the complete Deck and desktop matrix succeeds.
   The weekly lock-file commit also waits for both hosts.

Every job joins the tailnet and pushes each new package to the private
Attic cache as soon as it appears (`attic watch-store`), including when the
build fails. Packages already on cache.nixos.org are skipped. Unfree
packages are cached too, since only token holders can download.

To add a slow package to the parallel jobs, add it to `ci.heavyPackages` in
the host's `default.nix`.

Cache: https://cache.zoe.dev.br/nixos (Attic on vps-main, behind Caddy +
Cloudflare; private, 30-day retention of unused packages). Machines
authenticate with the pull token in `/etc/nix/netrc` (Bitwarden item
`nixos: attic`; the installer writes it). CI uploads over Tailscale to
`http://vps-main:8090`. Secrets: `ATTIC_TOKEN`, `TS_OAUTH_CLIENT_ID`,
`TS_OAUTH_SECRET`.
