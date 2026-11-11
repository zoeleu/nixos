# nvme-4k: switch an NVMe drive to 4K logical sectors (and its LUKS to 4K
# crypto sectors) without losing what's on it. Run from the installer ISO,
# never from the system on that drive.
#
#   nvme-4k <nvme-disk> <backup-disk>      e.g. nvme-4k /dev/nvme0n1 /dev/sdb
#
#   1. backup   ERASES <backup-disk>, then copies every partition of the
#               NVMe to it: ext2/3/4 (plain or inside LUKS) as e2image raw
#               images (used blocks only), FAT as files, plus the GPT, LUKS
#               headers and metadata. Checks the copies (e2fsck).
#   2. format   ERASES the NVMe: `nvme format` to the drive's 4096-byte
#               LBA format.
#   3. restore  Recreates the same partitions (same GPT disk/partition GUIDs,
#               names, types, so firmware boot entries and by-partlabel paths
#               keep working), LUKS2 with the same UUID/cipher and 4K crypto
#               sectors, FAT with the same serial, then writes the images back
#               and checks them.
#
# It asks for the old disk passphrase (backup) and the new one, twice
# (restore). Progress lives on the backup disk (label NVME4K-BACKUP), so after
# a crash or reboot running the same command again continues where it
# stopped; the NVMe is only formatted once its backup is complete. The backup
# is left alone at the end: delete it once the system boots.
#
# Random-key swap partitions (no signature) are recreated empty; plain swap
# gets mkswap with its old UUID. Anything else (NTFS, btrfs, LVM...) stops the
# script before it changes anything. LUKS tokens (TPM, FIDO2) and extra
# keyslots are not carried over: re-enroll them afterwards.
#
# For tests: NVME_4K_YES=1 skips the typed confirmations, NVME_4K_KEY_FILE
# supplies the passphrase (old and new), NVME_4K_STOP_AFTER=backup|format
# stops after that phase.

backup_label=NVME4K-BACKUP
run=/run/nvme-4k

die() { echo "nvme-4k: $*" >&2; exit 1; }
say() { printf '\n==> %s\n' "$*"; }

confirm() {
  [[ ${NVME_4K_YES:-} == 1 ]] && return 0
  local answer
  read -r -p "$1 Type '$2' to continue: " answer
  [[ $answer == "$2" ]] || die "cancelled, nothing more was changed"
}

key_args=()
[[ -n ${NVME_4K_KEY_FILE:-} ]] && key_args=(--key-file "$NVME_4K_KEY_FILE")

part_dev() { if [[ $1 =~ [0-9]$ ]]; then echo "${1}p$2"; else echo "$1$2"; fi; }
fs_type() { blkid -p -o value -s TYPE "$1" 2>/dev/null || true; }
fs_tag() { blkid -p -o value -s "$2" "$1" 2>/dev/null || true; }
# "KEY: value" fields of dumpe2fs -h
e2_field() { dumpe2fs -h "$1" 2>/dev/null | sed -n "s/^$2: *//p" | head -1; }

# Per-partition facts saved by the backup (part<N>.env)
load_meta() {
  kind="" node="" fat_serial="" fat_label="" fat_bits="" swap_uuid="" swap_label=""
  luks_uuid="" luks_cipher="" luks_keybits="" luks_label="" luks_flags=""
  # shellcheck source=/dev/null
  source "$1"
}

cleanup() {
  set +e
  for m in old new esp; do mountpoint -q "$run/$m" && umount "$run/$m"; done
  for d in nvme4k-old nvme4k-new; do [[ -e /dev/mapper/$d ]] && cryptsetup close "$d"; done
  mountpoint -q "$run/backup" && { sync; umount "$run/backup"; }
}

# --- checks (nothing is changed before the first confirmation) ---

[[ $# -eq 2 ]] || die "usage: nvme-4k <nvme-disk> <backup-disk>"
[[ $EUID -eq 0 ]] || die "run as root"
src=$(readlink -f "$1")
bk=$(readlink -f "$2")
[[ -b $src && -b $bk ]] || die "$1 and $2 must be block devices"
[[ $src != "$bk" ]] || die "the NVMe and the backup disk are the same device"
[[ $(lsblk -dno TYPE "$src") == disk && $(lsblk -dno TYPE "$bk") == disk ]] ||
  die "give whole disks (/dev/nvme0n1, /dev/sdb), not partitions"
[[ $(basename "$src") =~ ^nvme[0-9]+n[0-9]+$ ]] || die "$src is not an NVMe namespace"
ctrl=/dev/$(basename "$src" | sed 's/n[0-9]*$//')

mkdir -p "$run"/{backup,old,new,esp}
trap cleanup EXIT
cleanup # leftovers of an interrupted run
set -e # cleanup turns it off

for d in "$src" "$bk"; do
  if lsblk -nrpo NAME,MOUNTPOINTS "$d" | awk 'NF > 1' | grep -q . ||
     lsblk -nrpo TYPE "$d" | grep -qv -e disk -e part; then
    lsblk -o NAME,TYPE,MOUNTPOINTS "$d" >&2
    die "$d is in use (mounted, swap or an open LUKS/LVM device); boot the installer and leave it alone"
  fi
done

serial=$(lsblk -dno SERIAL "$src" | xargs)
model=$(lsblk -dno MODEL "$src" | xargs)
idns=$(nvme id-ns "$src" -o json)
lbaf=$(jq -r '[.lbafs | to_entries[] | select(.value.ds == 12 and .value.ms == 0) | .key][0] // empty' <<<"$idns")
[[ -n $lbaf ]] || die "$model has no 4096-byte LBA format without metadata"

state=$run/backup/nvme-4k
resume=0
if [[ $(fs_tag "$bk" LABEL) == "$backup_label" ]]; then
  mount "$bk" "$run/backup"
  if [[ -e $state/backup.done ]]; then
    [[ $(cat "$state/serial") == "$serial" ]] ||
      die "$bk holds the backup of another drive (serial $(cat "$state/serial"))"
    resume=1
  else
    umount "$run/backup" # an unfinished backup: start it over
  fi
fi

if [[ $resume -eq 0 && $(blockdev --getss "$src") -eq 4096 ]]; then
  echo "$src already uses 4096-byte sectors; nothing to do"
  exit 0
fi

# --- 1. backup ---

if [[ $resume -eq 0 ]]; then
  say "Reading $model ($serial), $src"
  plan=$(mktemp -d)
  sfdisk --json "$src" > "$plan/gpt.json"
  [[ $(jq -r .partitiontable.label "$plan/gpt.json") == gpt ]] || die "$src has no GPT"
  oss=$(jq -r '.partitiontable.sectorsize // 512' "$plan/gpt.json")
  need=$((1024 * 1024 * 1024)) # headroom

  mapfile -t parts < <(jq -r '.partitiontable.partitions[] | "\(.node) \(.start)"' "$plan/gpt.json")
  meta() { printf '%s=%q\n' "$1" "$2" >> "$plan/part$n.env"; }
  n=0
  for p in "${parts[@]}"; do
    read -r node start <<<"$p"
    n=$((n + 1))
    (( start * oss % 4096 == 0 )) || die "$node doesn't start on a 4K boundary"
    t=$(fs_type "$node")
    : > "$plan/part$n.env"
    meta node "$node"
    case "$t" in
      crypto_LUKS)
        cryptsetup luksDump "$node" > "$plan/part$n.luksdump"
        echo "Unlocking $node (the current disk passphrase):"
        cryptsetup open --readonly "${key_args[@]}" "$node" nvme4k-old
        inner=$(fs_type /dev/mapper/nvme4k-old)
        [[ $inner =~ ^ext[234]$ ]] || die "$node holds $inner, only ext2/3/4 inside LUKS is supported"
        dev=/dev/mapper/nvme4k-old
        meta kind luks
        meta luks_uuid "$(cryptsetup luksUUID "$node")"
        meta luks_cipher "$(sed -n 's/^[[:space:]]*cipher:[[:space:]]*//p' "$plan/part$n.luksdump" | head -1)"
        meta luks_keybits "$(sed -n 's/^[[:space:]]*Cipher key:[[:space:]]*\([0-9]*\) bits/\1/p' "$plan/part$n.luksdump" | head -1)"
        meta luks_label "$(sed -n 's/^Label:[[:space:]]*//p' "$plan/part$n.luksdump" | sed 's/^(no label)$//')"
        meta luks_flags "$(sed -n 's/^Flags:[[:space:]]*//p' "$plan/part$n.luksdump" | sed 's/^(no flags)$//')"
        if sed -n '/^Tokens:/,/^Digests:/p' "$plan/part$n.luksdump" | grep -q '^  [0-9]*:'; then
          echo "note: $node has LUKS tokens (TPM/FIDO2); they won't exist on the new disk, re-enroll them afterwards"
        fi
        ;;
      ext2 | ext3 | ext4) dev=$node; meta kind ext ;;
      vfat)
        meta kind vfat
        meta fat_serial "$(fs_tag "$node" UUID)"
        meta fat_label "$(fs_tag "$node" LABEL)"
        meta fat_bits "$(fs_tag "$node" VERSION | tr -dc 0-9)"
        mount -o ro "$node" "$run/esp"
        need=$((need + $(du -sb "$run/esp" | cut -f1)))
        umount "$run/esp"
        continue
        ;;
      swap)
        meta kind swap
        meta swap_uuid "$(fs_tag "$node" UUID)"
        meta swap_label "$(fs_tag "$node" LABEL)"
        continue
        ;;
      "") meta kind empty; continue ;; # e.g. random-key swap
      *) die "$node holds $t, which this script can't carry over" ;;
    esac
    # ext2/3/4, plain or inside LUKS
    bs=$(e2_field "$dev" "Block size")
    (( bs >= 4096 )) || die "$node: ext block size $bs can't live on a 4096-byte-sector disk"
    echo "Checking $node (read-only)..."
    e2fsck -fn "$dev" || die "$node has filesystem errors; fix them first (e2fsck from the installer)"
    need=$((need + ($(e2_field "$dev" "Block count") - $(e2_field "$dev" "Free blocks")) * bs * 11 / 10))
    [[ $t == crypto_LUKS ]] && cryptsetup close nvme4k-old
  done

  have=$(blockdev --getsize64 "$bk")
  (( need <= have )) || die "the backup needs about $((need >> 30)) GiB, $bk has $((have >> 30)) GiB"

  say "About to ERASE the backup disk"
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MODEL "$bk"
  confirm "Everything on $bk ($(lsblk -dno MODEL "$bk" | xargs)) will be deleted." ERASE

  wipefs -a "$bk"
  mkfs.ext4 -q -F -L "$backup_label" "$bk"
  mount "$bk" "$run/backup"
  mkdir -p "$state"
  cp "$plan"/* "$state"/
  echo "$serial" > "$state/serial"
  exec > >(tee -a "$state/log") 2>&1

  for env in "$state"/part*.env; do
    n=$(basename "$env" .env); n=${n#part}
    load_meta "$env"
    case "$kind" in
      luks | ext)
        dev=$node
        if [[ $kind == luks ]]; then
          cryptsetup luksHeaderBackup "$node" --header-backup-file "$state/part$n.luksheader"
          echo "Unlocking $node again for the copy:"
          cryptsetup open --readonly "${key_args[@]}" "$node" nvme4k-old
          dev=/dev/mapper/nvme4k-old
        fi
        say "Copying $node -> part$n.img (used blocks only)"
        e2image -ra -p "$dev" "$state/part$n.img"
        [[ $kind == luks ]] && cryptsetup close nvme4k-old
        e2fsck -fn "$state/part$n.img" || die "the copy of $node doesn't check out"
        ;;
      vfat)
        say "Copying the files of $node"
        mount -o ro "$node" "$run/esp"
        mkdir -p "$state/part$n.files"
        cp -a "$run/esp/." "$state/part$n.files/"
        umount "$run/esp"
        ;;
    esac
  done
  sync
  touch "$state/backup.done"
  say "Backup complete on $bk"
else
  exec > >(tee -a "$state/log") 2>&1
  say "Continuing: the backup on $bk is complete"
fi
[[ ${NVME_4K_STOP_AFTER:-} == backup ]] && exit 0

# --- 2. format ---

if [[ $(blockdev --getss "$src") -ne 4096 ]]; then
  say "About to ERASE the NVMe and switch it to 4096-byte sectors"
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MODEL "$src"
  confirm "Everything on $src ($model, $serial) will be deleted; the backup on $bk stays." FORMAT
  nvme format "$src" --lbaf="$lbaf" --ses=0 --force
  nvme ns-rescan "$ctrl" || true
  blockdev --rereadpt "$src" 2>/dev/null || true
  udevadm settle
  [[ $(blockdev --getss "$src") -eq 4096 ]] ||
    die "the drive was formatted but Linux still sees $(blockdev --getss "$src")-byte sectors; reboot the installer and run this again"
fi
touch "$state/format.done"
[[ ${NVME_4K_STOP_AFTER:-} == format ]] && exit 0

# --- 3. restore ---

if [[ ! -e $state/restore.done ]]; then
  say "Recreating the partitions"
  gpt=$state/gpt.json
  oss=$(jq -r '.partitiontable.sectorsize // 512' "$gpt")
  echo 'label: gpt' | sfdisk -q --wipe always "$src"
  last=$(sfdisk --json "$src" | jq -r .partitiontable.lastlba)
  {
    echo "label: gpt"
    echo "label-id: $(jq -r .partitiontable.id "$gpt")"
    echo "unit: sectors"
    jq -r '.partitiontable.partitions[] | [.start, .size, .type, .uuid, (.name // ""), (.attrs // "")] | @tsv' "$gpt" |
      while IFS=$'\t' read -r start size type uuid name attrs; do
        first=$((start * oss / 4096))
        end=$(((start + size) * oss / 4096)) # exclusive, rounded down to 4K
        (( end > last + 1 )) && end=$((last + 1)) # 4K GPT keeps a little more at the end
        line="start=$first, size=$((end - first)), type=$type, uuid=$uuid"
        [[ -n $name ]] && line+=", name=\"$name\""
        [[ -n $attrs ]] && line+=", attrs=\"$attrs\""
        echo "$line"
      done
  } | sfdisk -q --wipe always --wipe-partitions always "$src"
  partx -u "$src" 2>/dev/null || true
  udevadm settle

  for env in "$state"/part*.env; do
    n=$(basename "$env" .env); n=${n#part}
    load_meta "$env"
    node=$(part_dev "$src" "$n")
    [[ -b $node ]] || die "$node didn't appear"
    case "$kind" in
      vfat)
        say "Restoring the files of $node"
        args=(-S 4096)
        [[ -n $fat_bits ]] && args+=(-F "$fat_bits")
        [[ -n $fat_serial ]] && args+=(-i "${fat_serial//-/}")
        [[ -n $fat_label ]] && args+=(-n "$fat_label")
        mkfs.vfat "${args[@]}" "$node" > /dev/null
        mount "$node" "$run/esp"
        cp -rT --preserve=timestamps "$state/part$n.files" "$run/esp"
        umount "$run/esp"
        ;;
      swap)
        args=(-U "$swap_uuid")
        [[ -n $swap_label ]] && args+=(-L "$swap_label")
        mkswap "${args[@]}" "$node" > /dev/null
        ;;
      empty) wipefs -a "$node" > /dev/null ;;
      luks | ext)
        dev=$node
        if [[ $kind == luks ]]; then
          say "Creating LUKS2 on $node with 4096-byte sectors (same UUID)"
          args=(--type luks2 --sector-size 4096 --uuid "$luks_uuid")
          [[ -n $luks_cipher ]] && args+=(--cipher "$luks_cipher")
          [[ -n $luks_keybits ]] && args+=(--key-size "$luks_keybits")
          [[ -n $luks_label ]] && args+=(--label "$luks_label")
          echo "Choose the disk passphrase (it can be the same as before):"
          cryptsetup luksFormat -q --verify-passphrase "${args[@]}" "${key_args[@]}" "$node"
          open_args=()
          for f in $luks_flags; do
            case "$f" in
              allow-discards) open_args+=(--allow-discards) ;;
              same-cpu-crypt) open_args+=(--perf-same_cpu_crypt) ;;
              submit-from-crypt-cpus) open_args+=(--perf-submit_from_crypt_cpus) ;;
              no-read-workqueue) open_args+=(--perf-no_read_workqueue) ;;
              no-write-workqueue) open_args+=(--perf-no_write_workqueue) ;;
            esac
          done
          (( ${#open_args[@]} )) && open_args+=(--persistent)
          echo "Unlocking it (the new passphrase):"
          cryptsetup open "${open_args[@]}" "${key_args[@]}" "$node" nvme4k-new
          dev=/dev/mapper/nvme4k-new
        fi
        img=$state/part$n.img
        room=$(blockdev --getsize64 "$dev")
        bs=$(e2_field "$img" "Block size")
        blocks=$(e2_field "$img" "Block count")
        if (( blocks * bs > room )); then
          # the 4K GPT and 4K-rounded partition end take a few KiB from the
          # last partition: shrink the filesystem in the image to fit
          say "Shrinking the filesystem by $(( (blocks * bs - room) / 1024 )) KiB to fit"
          e2fsck -fy "$img" > /dev/null
          resize2fs "$img" "$((room / bs))"
        fi
        say "Writing part$n.img -> $node"
        e2image -ra -p "$img" "$dev"
        e2fsck -fn "$dev" || die "$node doesn't check out after the copy; the backup is untouched, run this again"
        [[ $kind == luks ]] && cryptsetup close nvme4k-new
        ;;
    esac
  done
  sync
  touch "$state/restore.done"
fi

say "Done: $src now uses $(blockdev --getss "$src")-byte sectors"
lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL,LOG-SEC "$src"
for env in "$state"/part*.env; do
  grep -q '^kind=luks' "$env" || continue
  n=$(basename "$env" .env); n=${n#part}
  echo "$(part_dev "$src" "$n"): LUKS sector size $(cryptsetup luksDump "$(part_dev "$src" "$n")" | sed -n 's/^[[:space:]]*sector:[[:space:]]*//p' | head -1)"
done
echo "The backup stays on $bk ($backup_label); wipe it once the system boots fine."
