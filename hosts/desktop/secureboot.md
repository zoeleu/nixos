# Desktop Secure Boot

The desktop uses Lanzaboote v1.2.0 with systemd-boot (`secureboot.nix`).
Every time a generation is installed, the desktop itself signs the boot
manager and one small stub per generation. The stub carries the hashes of
its kernel and initrd and the kernel command line, so changing any of them
on the ESP stops the boot. The kernel and initrd files next to it are not
signed themselves (`sbctl verify` lists `kernel-*.efi` as unsigned); that is
expected, the stub checks them.

Nothing is signed in CI and no signing key leaves this machine, except
encrypted in `secrets/secureboot.yaml`.

The kernel runs in lockdown **integrity** mode (confidentiality would block
perf and tracing). Consequences: no hibernation, no `/dev/mem`, MSR writes
or kexec of unsigned kernels, and **out-of-tree kernel modules don't load**
(nixpkgs signs only the modules built with the kernel). None are used today;
adding one to `boot.extraModulePackages` means it silently won't load.

## What Secure Boot does and doesn't do here

It stops someone with a few minutes at the PC from replacing the boot files
with ones that record the disk passphrase. It does not encrypt anything
(LUKS does) and does not protect a running system from root.

Limits to know:

- Microsoft's certificates stay enrolled (Windows on the other drive, GPU
  option ROM), so anything Microsoft signed also boots. A patient attacker
  can still show a fake passphrase prompt that way.
- Without a firmware administrator password, Secure Boot can simply be
  switched off again.
- The real fix for both is binding the disk to the TPM (PCR 7) with a PIN:
  any change to the Secure Boot state then makes the usual PIN prompt
  disappear and the recovery passphrase prompt appear. Not set up yet.

## State on 2026-11-12

Done:

- RSA PK, KEK and db keys generated with sbctl, and enrolled together with
  Microsoft's and the firmware's built-in certificates. Setup Mode is off.
- The new configuration was built and installed into a scratch directory
  with the real key: boot manager and stub verify against `secureboot/db.pem`.
- Pre-enrolment ESP backup, on the encrypted disk:
  `/var/lib/secureboot/esp-before-enrollment.tar`.

Not done (in this order):

1. **Deploy.** Commit and push; once CI moved `built`, the desktop switches
   by itself and Lanzaboote rewrites the ESP: signed boot manager, one signed
   stub for each of the last 10 generations, `default nixos-*`, editor off.
   Check with `sudo sbctl verify` (only `kernel-*.efi` may be unsigned) and
   `bootctl list`.
2. **Remove the old boot entries.** The previous bootloader's entries stay
   in `/boot/loader/entries/` and point at files Lanzaboote has deleted:

   ```bash
   sudo rm /boot/loader/entries/nixos-*.conf
   ```
3. **Reboot once with Secure Boot still off**, to see that the signed entry,
   the Zen kernel, lockdown and `intel_iommu=on` boot fine.
   `cat /sys/kernel/security/lockdown` must show `[integrity]`.
4. **Firmware setup** (Del at power-on), MSI Click BIOS 5:
   - Settings > Advanced > Windows OS Configuration > Secure Boot:
     Secure Boot **Enabled**, Secure Boot Mode **Custom**.
   - Same menu, Image Execution Policy: set Option ROM, Removable Media and
     Fixed Media to **Deny Execute**. This board (H310M PRO-M2 PLUS, MS-7C08,
     BIOS 1.70) is on sbctl's [FQ0001 list](https://github.com/Foxboron/sbctl/wiki/FQ0001):
     its default is *Always Execute*, which boots unsigned files even with
     Secure Boot on. If the menu instead offers Secure Boot Preset, choose
     **Maximum Security**.
   - Do not restore factory keys or "Enroll all Factory Default keys": that
     replaces ours.
   - Settings > Security: set an **Administrator Password** (save it in
     Bitwarden).
5. **Check.** `bootctl status` (Secure Boot: enabled), `sudo sbctl status`
   (Setup Mode disabled; the FQ0001 warning stays, it only looks at the
   board's name), `cat /sys/kernel/security/lockdown`. Then prove the policy
   works: boot the installer USB stick. It is not signed by us or Microsoft,
   so the firmware must refuse it.

If the signed entry doesn't boot: switch Secure Boot off in the firmware.
Everything boots as before, signatures are just not checked.

## Keys and recovery

`secureboot/` holds only public certificates and the owner GUID.
`secrets/secureboot.yaml` holds the PK, KEK and db private keys,
certificates and GUID, encrypted for zoe's age key and this desktop's SSH
host key. The Deck and CI cannot decrypt it. The repo is public, so those
keys are as safe as the age key in Bitwarden.

sops-nix puts `db_key` at `/var/lib/sbctl/keys/db/db.key` (mode 0400), which
is the path Lanzaboote signs with. The certificate is pinned in
`secureboot/db.pem`, so a different key fails verification. The PK and KEK
private keys under `/var/lib/sbctl` are not needed for daily signing.

Reinstalling: `install-nixos` handles it. Lanzaboote signs during
`nixos-install`, before sops-nix has ever run, so the installer adds the
new SSH host key to both rules in `.sops.yaml` (replacing the old desktop
key), re-encrypts, and writes `db_key` to
`/mnt/var/lib/sbctl/keys/db/db.key` itself. It checks that the admin age
key opens `secrets/secureboot.yaml` before erasing anything. Commit and push
those changes after the first boot. The Deck is never added to the Secure
Boot rule.

The installer stick itself needs Secure Boot switched off to boot (step 5).

Never add decrypted files or private keys to git or the Nix store. To rotate
keys: generate new ones, update `secrets/secureboot.yaml` and `secureboot/`,
re-sign the ESP, then enrol the new certificates. Changing the SOPS file
alone does not change what the firmware trusts.
