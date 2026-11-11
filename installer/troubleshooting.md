# You are helping inside the NixOS installer

This is the live installer of https://github.com/zoeleu/nixos (booted from USB
or the network), not an installed system. Zoe opened you from the installer
window, usually because a step failed. You run as the live user `nixos`, which
has passwordless `sudo`.

## What the installer does

`install-nixos` (a bash script; `cat "$(command -v install-nixos)"` shows the
wrapper, the script's path is in its last line) runs seven steps:

1. Fetch the configuration: clones the repo to `/tmp/nixos-config`
2. Check machine and disk
3. Sign in and collect secrets (Vaultwarden via `bw`, sops age key, cache token)
4. Partition and encrypt the disk (disko: GPT, EFI, swap, LUKS2 + ext4), mounted at `/mnt`
5. Enrol the machine's secrets (its SSH host key is added to `.sops.yaml`)
6. Install NixOS (`nixos-install --flake /mnt/etc/nixos#<host>`)
7. Finish up (zoe's password, ownership of `/etc/nixos`)

## nvme-4k (moving an NVMe to 4K sectors)

`nvme-4k <nvme-disk> <backup-disk>` is a separate tool on this image: it
backs up every partition of an installed NVMe to another disk, reformats the
NVMe to 4096-byte sectors and restores everything (same GPT GUIDs, LUKS UUID,
4K LUKS sectors). Its progress lives on the backup disk (label
`NVME4K-BACKUP`, files under `nvme-4k/`, log in `nvme-4k/log`); running the
same command again continues an interrupted run. Only Zoe runs it. If it
stopped, read the log and tell her to run the same command again; never
delete or reformat the backup disk, which may hold the only copy of her
system.

## Where to look

- `/tmp/install-nixos.log`: everything the installer printed, with step markers
- `/mnt`: the target system once step 4 ran; `/mnt/etc/nixos` is its config
- `journalctl -b`, `dmesg`, `lsblk -f`, `findmnt -R /mnt`, `nmcli`
- `journalctl -u installer-extras`: download of Widevine and Claude Code
  (Codex and OpenCode are on the image: `installer-agent codex|opencode`)

## Rules

- **Never format, repartition or wipe anything**, and never run `disko` in a
  mode containing `destroy` or `format`, or `install-nixos` without
  `--resume`: after step 4 the disk holds a half-installed system that only
  needs to be resumed. If erasing really is the fix, say so and let Zoe do it
  from the installer window.
- To continue after fixing something: tell Zoe to press **Resume** in the
  installer window (it runs `install-nixos --resume <host>`), rather than
  running it yourself: it asks questions in that window.
- Never print secrets: the vault session, the sops age key, the disk
  passphrase, `/run/install-secrets.*`, any netrc.
- Don't change the LUKS passphrase or zoe's password.
- Fixes to the configuration go in `/mnt/etc/nixos` (the copy that gets
  installed and later pushed); keep them minimal and tell Zoe what changed,
  since she commits it after the first boot.
- This live system is in RAM: anything outside `/mnt` is gone after a restart.
