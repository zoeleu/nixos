# Installs one of the machines in https://github.com/zoeleu/nixos onto a disk.
# Run on the installer ISO as root: install-nixos
#
#  1. clone the repo (latest main; falls back to the copy on the ISO)
#  2. pick a host (one with hosts/<host>/disko.nix) and a disk
#  3. write hosts/<host>/hardware-configuration.nix and disk.nix
#  4. partition + encrypt + format + mount with disko (asks the LUKS passphrase)
#  5. nixos-install from the flake, using the host's binary caches
#  6. set zoe's password
#
# Nothing is pushed: after the first boot, commit and push the two new files.

REPO_URL="https://github.com/zoeleu/nixos"
WORK=/tmp/nixos-config

red() { printf '\033[1;31m%s\033[0m\n' "$*"; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { red "Error: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"

bold "== NixOS installer for $REPO_URL"

# --- 1. network + repo ---
if ! curl -fsS --max-time 10 -o /dev/null https://cache.nixos.org/nix-cache-info; then
  red "No internet connection. Connect first (wifi: run 'nmtui'), then run install-nixos again."
  exit 1
fi
rm -rf "$WORK"
if git clone --quiet "$REPO_URL" "$WORK"; then
  echo "Using latest $REPO_URL ($(git -C "$WORK" log -1 --format='%h %s'))"
else
  red "Couldn't clone $REPO_URL; using the copy built into this ISO."
  cp -r "$ISO_REPO" "$WORK" && chmod -R u+w "$WORK"
  git -C "$WORK" init --quiet && git -C "$WORK" add -A
fi
cd "$WORK"

# --- 2a. host ---
mapfile -t hosts < <(for d in hosts/*/; do [ -f "$d/disko.nix" ] && basename "$d"; done)
[ "${#hosts[@]}" -gt 0 ] || die "no host in the repo has a disko.nix"
echo
bold "Machines that can be installed:"
for i in "${!hosts[@]}"; do echo "  $((i + 1))) ${hosts[$i]}"; done
read -rp "Install which one? [1] " n
n=${n:-1}
host=${hosts[$((n - 1))]:-}
[ -n "$host" ] || die "invalid choice"

# --- 2b. disk ---
boot_disk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /iso 2>/dev/null)" 2>/dev/null || true)
echo
bold "Disks (the USB stick this installer runs from is hidden):"
mapfile -t disks < <(lsblk -dno NAME,TYPE | awk -v skip="${boot_disk:-none}" '$2=="disk" && $1!=skip && $1!~/^(zram|loop)/ {print $1}')
[ "${#disks[@]}" -gt 0 ] || die "no disks found"
for i in "${!disks[@]}"; do
  d=${disks[$i]}
  printf '  %d) /dev/%-10s %8s  %s\n' "$((i + 1))" "$d" "$(lsblk -dno SIZE "/dev/$d")" "$(lsblk -dno MODEL "/dev/$d")"
  lsblk -no NAME,SIZE,FSTYPE,LABEL "/dev/$d" | tail -n +2 | sed 's/^/        /'
done
read -rp "Install onto which disk? " n
disk=${disks[$((n - 1))]:-}
[ -n "$disk" ] || die "invalid choice"
# stable name for the config: /dev/disk/by-id/..., not /dev/nvme0n1
byid=$(find /dev/disk/by-id/ -lname "*/$disk" ! -name '*-part*' | { grep -v '/wwn-\|/nvme-eui\.\|_[0-9]$' || true; } | sort | head -1)
[ -n "$byid" ] || byid=$(find /dev/disk/by-id/ -lname "*/$disk" | sort | head -1)
[ -n "$byid" ] || die "no /dev/disk/by-id name for /dev/$disk"

echo
red "ALL DATA ON THIS DISK WILL BE ERASED:"
echo "  $byid"
echo "  $(lsblk -dno SIZE,MODEL "/dev/$disk")"
lsblk -no NAME,SIZE,FSTYPE,LABEL "/dev/$disk" | tail -n +2 | sed 's/^/    /'
read -rp "Type the disk name ($disk) to erase it and install '$host': " confirm
[ "$confirm" = "$disk" ] || die "not confirmed, nothing was changed"

# --- 3. host files ---
cat > "hosts/$host/disk.nix" <<EOF
# Disk this machine is installed on (written by install-nixos)
{ disko.devices.disk.main.device = "$byid"; }
EOF
# disko owns filesystems/swap/LUKS, so leave them out of the hardware config
nixos-generate-config --no-filesystems --show-hardware-config > "hosts/$host/hardware-configuration.nix"
git add "hosts/$host/disk.nix" "hosts/$host/hardware-configuration.nix"

# --- 4. partition, encrypt, format, mount ---
echo
bold "Partitioning. You'll be asked for the disk encryption passphrase (typed at every boot)."
disko --mode destroy,format,mount --yes-wipe-all-disks --flake ".#$host" \
  || die "partitioning failed"

# --- 5. install ---
mkdir -p /mnt/etc
cp -a "$WORK" /mnt/etc/nixos
cd /mnt/etc/nixos
subs=$(nix eval --raw ".#nixosConfigurations.$host.config.nix.settings.substituters" --apply 'builtins.concatStringsSep " "')
keys=$(nix eval --raw ".#nixosConfigurations.$host.config.nix.settings.trusted-public-keys" --apply 'builtins.concatStringsSep " "')
# build in a folder on the new disk: the ISO's /tmp lives in RAM
mkdir -p /mnt/var/tmp/nix-build
echo
bold "Installing '$host'. This downloads several GB and may compile a few packages."
nixos-install --flake "/mnt/etc/nixos#$host" --no-root-passwd --no-channel-copy \
  --option build-dir /mnt/var/tmp/nix-build \
  --option extra-substituters "$subs" \
  --option extra-trusted-public-keys "$keys" \
  || die "nixos-install failed (fix and re-run: the disk is still mounted at /mnt)"
rm -rf /mnt/var/tmp/nix-build

# The config belongs to zoe: she commits (signed via Bitwarden's SSH agent)
# and pushes over SSH with her own key. Root's git trusts the folder
# (programs.git safe.directory in modules/common.nix) for nixos-rebuild.
git -C /mnt/etc/nixos remote set-url origin git@github.com:zoeleu/nixos.git 2>/dev/null || true
nixos-enter --root /mnt -c 'chown -R zoe:users /etc/nixos'

# --- 6. password ---
echo
bold "Set the password for zoe (sudo, SSH from Tailscale on hosts that allow it):"
until nixos-enter --root /mnt -c 'passwd zoe'; do red "Try again."; done

echo
bold "Done. Remove the USB stick and reboot."
echo "After logging in, sign in to Bitwarden (server https://vw.zoe.dev.br) and"
echo "enable its SSH agent, then save the machine's new files to GitHub:"
echo "  cd /etc/nixos && git commit -m '$host: hardware config' && git push"
