# Installs one of the machines in https://github.com/zoeleu/nixos onto a disk.
# Run on the installer ISO as root: install-nixos
#
#  1. clone the repo (latest main; falls back to the copy on the ISO)
#  2. pick a host (one with hosts/<host>/disko.nix) and a disk
#  3. get the passwords from Vaultwarden (or ask, and offer to save them)
#  4. write hosts/<host>/hardware-configuration.nix and disk.nix
#  5. partition + encrypt + format + mount with disko
#  6. nixos-install from the flake, using the host's binary caches
#  7. set zoe's password, hand /etc/nixos to zoe
#
# Vaultwarden (https://vw.zoe.dev.br): log in with SSO (Firefox kiosk) or the
# personal API key (no browser; Vaultwarden allows it with SSO enforced),
# then unlock with the master password. Item:
#   "nixos: <host>"  Login: password = zoe's password,
#                    hidden custom field "disk passphrase" = disk encryption passphrase
#   "nixos: attic"   Login: password = Attic pull token -> /etc/nix/netrc
#                    (private binary cache https://cache.zoe.dev.br/nixos)
#
# Nothing is pushed: after the first boot, commit and push the two new files.

REPO_URL="https://github.com/zoeleu/nixos"
VAULT_URL="https://vw.zoe.dev.br"
# Vaultwarden's fixed SSO organization identifier (what the server returns
# for zoe@zoe.dev.br); passing it skips the "SSO identifier" page
SSO_IDENTIFIER="00000000-01DC-01DC-01DC-000000000000"
WORK=/tmp/nixos-config
SECRETS=/run/install-secrets # tmpfs (RAM), removed at exit

red() { printf '\033[1;31m%s\033[0m\n' "$*"; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { red "Error: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"

mkdir -p "$SECRETS" && chmod 700 "$SECRETS"
BW_SESSION=""
cleanup() {
  rm -rf "$SECRETS"
  if [ -n "$BW_SESSION" ]; then bw logout >/dev/null 2>&1 || true; fi
  unset BW_CLIENTID BW_CLIENTSECRET
}
trap cleanup EXIT

# Ask for a secret twice (hidden); prints it
ask_secret() {
  local prompt=$1 a b
  while true; do
    read -rsp "$prompt: " a; echo >&2
    read -rsp "Again: " b; echo >&2
    [ -n "$a" ] && [ "$a" = "$b" ] && { printf '%s' "$a"; return; }
    red "Empty or not matching, try again." >&2
  done
}

bold "== NixOS installer for $REPO_URL"

# --- 1. network + repo ---
if ! curl -fsS --max-time 10 -o /dev/null https://cache.nixos.org/nix-cache-info; then
  red "No internet connection. Plug in Ethernet (or run 'nmtui'), then run install-nixos again."
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

# --- 3. passwords: Vaultwarden, or ask ---
item_name="nixos: $host"
user_pw="" disk_pw="" vault_item="" attic_token=""
echo
bold "Passwords from Vaultwarden ($VAULT_URL):"
echo "  1) SSO login in a full-screen browser (then your master password)"
echo "  2) personal API key (web vault: Account settings > Security > Keys)"
echo "  3) don't use the vault, type the passwords"
read -rp "Choice? [1] " login_method
login_method=${login_method:-1}
if [ "$login_method" = 1 ] || [ "$login_method" = 2 ]; then
  bw config server "$VAULT_URL" >/dev/null
  logged_in=0
  if [ "$login_method" = 1 ]; then
    # `bw login --sso` runs `xdg-open <url>` and waits for the browser to
    # come back to http://localhost:8065. Our xdg-open opens Firefox in a
    # kiosk (cage), as the console's user so it can use the screen; it's
    # closed once bw has the login.
    kiosk_user=${SUDO_USER:-nixos}
    mkdir -p "$SECRETS/bin"
    rm -rf /tmp/sso-firefox && install -d -o "$kiosk_user" -m 700 /tmp/sso-firefox
    cat > "$SECRETS/bin/xdg-open" <<EOF
#!/bin/sh
setsid sudo -u "$kiosk_user" XDG_RUNTIME_DIR="/run/user/\$(id -u "$kiosk_user")" \\
  cage -s -- firefox --kiosk --no-remote --profile /tmp/sso-firefox "\$1" \\
  >/tmp/sso-kiosk.log 2>&1 &
EOF
    chmod 755 "$SECRETS/bin/xdg-open"
    bold "Opening the SSO login full-screen. Sign in there; it closes by itself."
    echo "(If the screen stays black or it hangs: wait 10 minutes, or press"
    echo " Ctrl+Alt+F2 and run 'pkill cage'. Then pick the API key instead.)"
    if PATH="$SECRETS/bin:$PATH" timeout 600 bw login --sso "$SSO_IDENTIFIER" >/dev/null; then logged_in=1; fi
    pkill -f 'cage -s -- firefox' 2>/dev/null || true
    rm -rf /tmp/sso-firefox
    sleep 1; clear
  else
    read -rp "client_id: " BW_CLIENTID
    read -rsp "client_secret: " BW_CLIENTSECRET; echo
    export BW_CLIENTID BW_CLIENTSECRET
    if bw login --apikey >/dev/null; then logged_in=1; fi
  fi
  if [ "$logged_in" = 1 ]; then bold "Unlock the vault:"; fi
  if [ "$logged_in" = 1 ] && BW_SESSION=$(bw unlock --raw) && [ -n "$BW_SESSION" ]; then
    export BW_SESSION
    bw sync >/dev/null || true
    vault_item=$(bw list items --search "$item_name" | jq -c --arg n "$item_name" '[.[] | select(.name == $n)][0] // empty')
    if [ -n "$vault_item" ]; then
      user_pw=$(jq -r '.login.password // empty' <<<"$vault_item")
      disk_pw=$(jq -r '.fields[]? | select(.name == "disk passphrase") | .value // empty' <<<"$vault_item")
      echo "Found '$item_name' in the vault."
    else
      echo "No '$item_name' item in the vault yet."
    fi
    # age key for sops: lets this machine be added to .sops.yaml below
    age_key=$(bw list items --search "sops: age key" | jq -r '[.[] | select(.name == "sops: age key")][0].login.password // empty')
    if [ -n "$age_key" ]; then
      (umask 077; printf '%s\n' "$age_key" > "$SECRETS/age.key")
      age_key=""
      echo "Found the sops age key."
    fi
    # Pull token for the private Attic cache (cache.zoe.dev.br)
    attic_token=$(bw list items --search "nixos: attic" | jq -r '[.[] | select(.name == "nixos: attic")][0].login.password // empty')
    if [ -n "$attic_token" ]; then
      printf 'machine cache.zoe.dev.br\npassword %s\n' "$attic_token" > "$SECRETS/netrc"
      chmod 600 "$SECRETS/netrc"
      attic_token=""
      echo "Found the Attic cache token."
    else
      red "No 'nixos: attic' item in the vault: packages from cache.zoe.dev.br can't be downloaded and will be built locally."
    fi
  else
    BW_SESSION=""
    red "Vaultwarden login failed; asking for the passwords instead."
  fi
fi
asked=0
if [ -z "$disk_pw" ]; then disk_pw=$(ask_secret "Disk encryption passphrase (typed at every boot)"); asked=1; fi
if [ -z "$user_pw" ]; then user_pw=$(ask_secret "Password for zoe"); asked=1; fi
if [ -n "$BW_SESSION" ] && [ "$asked" = 1 ]; then
  read -rp "Save these to the vault as '$item_name'? [Y/n] " save
  if [ "${save,,}" != "n" ]; then
    if [ -n "$vault_item" ]; then
      jq --arg pw "$user_pw" --arg disk "$disk_pw" '
        .login.password = $pw
        | .fields = ([.fields[]? | select(.name != "disk passphrase")] + [{name: "disk passphrase", value: $disk, type: 1}])' <<<"$vault_item" \
        | bw encode | bw edit item "$(jq -r .id <<<"$vault_item")" >/dev/null && echo "Updated '$item_name'."
    else
      bw get template item | jq --arg n "$item_name" --arg pw "$user_pw" --arg disk "$disk_pw" '
        .type = 1 | .name = $n | .notes = "Created by install-nixos"
        | .login = {username: "zoe", password: $pw}
        | .fields = [{name: "disk passphrase", value: $disk, type: 1}]' \
        | bw encode | bw create item >/dev/null && echo "Saved '$item_name'."
    fi
  fi
fi
printf '%s' "$disk_pw" > "$SECRETS/disk.key"

# --- 4. host files ---
cat > "hosts/$host/disk.nix" <<EOF
# Disk this machine is installed on (written by install-nixos)
{ disko.devices.disk.main.device = "$byid"; }
EOF
# disko owns filesystems/swap/LUKS, so leave them out of the hardware config
nixos-generate-config --no-filesystems --show-hardware-config > "hosts/$host/hardware-configuration.nix"
git add "hosts/$host/disk.nix" "hosts/$host/hardware-configuration.nix"

# --- 5. partition, encrypt, format, mount ---
# disko.nix reads the passphrase from /tmp/disk.key; keep the real file in
# RAM-only $SECRETS and link it there only for this step
echo
bold "Partitioning and encrypting $byid ..."
ln -sf "$SECRETS/disk.key" /tmp/disk.key
disko --mode destroy,format,mount --yes-wipe-all-disks --flake ".#$host" \
  || die "partitioning failed"
rm -f /tmp/disk.key "$SECRETS/disk.key"

# --- 5b. secrets: this machine's SSH host key decrypts secrets/*.yaml ---
# Create the host key now (instead of on first boot) so its age key can be
# added to .sops.yaml and the secrets re-encrypted before installing.
mkdir -p /mnt/etc/ssh
if [ ! -f /mnt/etc/ssh/ssh_host_ed25519_key ]; then
  ssh-keygen -q -t ed25519 -N "" -C "root@$host" -f /mnt/etc/ssh/ssh_host_ed25519_key
fi
host_age=$(ssh-to-age < /mnt/etc/ssh/ssh_host_ed25519_key.pub)
if grep -q "$host_age" .sops.yaml; then
  echo "This machine can already decrypt the secrets."
elif [ -f "$SECRETS/age.key" ]; then
  # replace an older key for this host, then add this one
  yq -i "(.creation_rules[0].key_groups[0].age) |= map(select(line_comment != \"$host\"))" .sops.yaml
  yq -i ".creation_rules[0].key_groups[0].age += [\"$host_age\"] | .creation_rules[0].key_groups[0].age[-1] line_comment = \"$host\"" .sops.yaml
  for f in secrets/*.yaml; do SOPS_AGE_KEY_FILE="$SECRETS/age.key" sops updatekeys -y "$f"; done
  git add .sops.yaml secrets
  echo "Added '$host' to .sops.yaml and re-encrypted the secrets."
else
  red "Couldn't add '$host' to the secrets (no 'sops: age key' from the vault)."
  red "Its secrets (e.g. the Attic cache token) won't decrypt until you add"
  red "  $host_age"
  red "to .sops.yaml and run 'sops updatekeys' on secrets/*.yaml."
fi
rm -f "$SECRETS/age.key"

# --- 6. install ---
mkdir -p /mnt/etc
cp -a "$WORK" /mnt/etc/nixos
cd /mnt/etc/nixos
subs=$(nix eval --raw ".#nixosConfigurations.$host.config.nix.settings.substituters" --apply 'builtins.concatStringsSep " "')
keys=$(nix eval --raw ".#nixosConfigurations.$host.config.nix.settings.trusted-public-keys" --apply 'builtins.concatStringsSep " "')
# build in a folder on the new disk: the ISO's /tmp lives in RAM
mkdir -p /mnt/var/tmp/nix-build
echo
bold "Installing '$host'. This downloads several GB and may compile a few packages."
netrc_opts=()
if [ -f "$SECRETS/netrc" ]; then
  # the private Attic cache, for this install's downloads (the installed
  # system gets the token from secrets/attic.yaml via sops-nix)
  netrc_opts=(--option netrc-file "$SECRETS/netrc")
fi
nixos-install --flake "/mnt/etc/nixos#$host" --no-root-passwd --no-channel-copy \
  --option build-dir /mnt/var/tmp/nix-build \
  --option extra-substituters "$subs" \
  --option extra-trusted-public-keys "$keys" \
  "${netrc_opts[@]}" \
  || die "nixos-install failed (fix and re-run: the disk is still mounted at /mnt)"
rm -rf /mnt/var/tmp/nix-build

# --- 7a. zoe's password (stored hashed in /etc/shadow) ---
printf 'zoe:%s\n' "$user_pw" | nixos-enter --root /mnt -c 'chpasswd' \
  || die "setting zoe's password failed; run: nixos-enter --root /mnt -c 'passwd zoe'"
user_pw="" disk_pw=""
echo "Set zoe's password."

# --- 7b. the config belongs to zoe ---
# She commits (signed via Bitwarden's SSH agent) and pushes over SSH with
# her own key. Root's git trusts the folder (programs.git safe.directory in
# modules/common.nix) for nixos-rebuild.
git -C /mnt/etc/nixos remote set-url origin git@github.com:zoeleu/nixos.git 2>/dev/null || true
nixos-enter --root /mnt -c 'chown -R zoe:users /etc/nixos'

echo
bold "Done. Remove the USB stick and reboot."
echo "After logging in, sign in to Bitwarden ($VAULT_URL) and enable its SSH"
echo "agent, then save the machine's new files to GitHub:"
echo "  cd /etc/nixos && git commit -m '$host: hardware config' && git push"
