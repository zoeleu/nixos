# installer/nvme-4k.sh on an emulated NVMe: the desktop's layout (ESP, empty
# random-key swap, LUKS2 + ext4 to the end of the disk) on 512-byte sectors,
# moved to 4096 through a backup disk, interrupted after each phase and
# resumed. Checks that GUIDs, UUIDs, the FAT serial and every file survive.
{ pkgs, ... }:

let
  passphrase = "correct horse";
in
{
  name = "nvme-4k";

  nodes.machine = { pkgs, ... }: {
    virtualisation = {
      memorySize = 2048;
      emptyDiskImages = [ 1536 ]; # /dev/vdb: the backup disk
      # the NVMe: an image the test script creates in the VM's state dir
      qemu.options = [
        "-drive file=$TMPDIR/nvme.qcow2,if=none,id=nvm,format=qcow2"
        "-device nvme,serial=NVME4KTEST,drive=nvm"
      ];
    };
    environment.systemPackages = [
      (import ../installer/nvme-4k.nix { inherit pkgs; })
      pkgs.cryptsetup
      pkgs.gptfdisk
      pkgs.dosfstools
      pkgs.e2fsprogs
      pkgs.attr
      pkgs.jq
    ];
  };

  testScript = ''
    import subprocess
    subprocess.run(["${pkgs.qemu}/bin/qemu-img", "create", "-f", "qcow2",
                    str(machine.state_dir / "nvme.qcow2"), "1G"], check=True)

    machine.wait_for_unit("multi-user.target")
    machine.succeed("echo -n '${passphrase}' > /tmp/key")
    nvme = "/dev/nvme0n1"
    assert machine.succeed(f"blockdev --getss {nvme}").strip() == "512"

    # --- the desktop's layout (hosts/desktop/disko.nix), small ---
    machine.succeed(
      f"sgdisk -n1:1M:+64M -t1:EF00 -c1:disk-main-ESP"
      f" -n2:0:+32M -t2:8200 -c2:disk-main-swap"
      f" {nvme}",
      # root up to the very last usable sector, the worst case for the 4K GPT
      f"sgdisk -n3:0:$(sgdisk -E {nvme}) -t3:8309 -c3:disk-main-root {nvme}",
      "udevadm settle",
      f"mkfs.vfat -n BOOT {nvme}p1",
      "mkdir -p /mnt/esp && mount /dev/nvme0n1p1 /mnt/esp",
      "mkdir -p /mnt/esp/EFI/BOOT && echo bootloader > /mnt/esp/EFI/BOOT/BOOTX64.EFI",
      "umount /mnt/esp",
      f"cryptsetup luksFormat -q --type luks2 --key-file /tmp/key {nvme}p3",
      # persistent flags, like crypttab options would be
      f"cryptsetup open --key-file /tmp/key --allow-discards --persistent {nvme}p3 old",
      "mkfs.ext4 -q /dev/mapper/old",
      "mkdir -p /mnt/root && mount /dev/mapper/old /mnt/root",
      "mkdir -p /mnt/root/home/zoe /mnt/root/nix/store",
      "head -c 50M /dev/urandom > /mnt/root/home/zoe/data",
      "ln /mnt/root/home/zoe/data /mnt/root/nix/store/hardlink",
      "ln -s ../home/zoe/data /mnt/root/nix/symlink",
      "setfattr -n user.test -v kept /mnt/root/home/zoe/data",
      "chown 1000:100 /mnt/root/home/zoe/data",
      "sha256sum /mnt/root/home/zoe/data | cut -d' ' -f1 > /tmp/sum",
      "umount /mnt/root && cryptsetup close old",
    )
    assert "512" in machine.succeed(f"cryptsetup luksDump {nvme}p3 | grep sector")

    def ids():
        return machine.succeed(
          f"sfdisk --json {nvme} | jq -c '[.partitiontable.id, [.partitiontable.partitions[] | [.uuid, .name, .type]]]';"
          f"cryptsetup luksUUID {nvme}p3; blkid -p -s UUID -o value {nvme}p1")
    before = ids()

    run = "NVME_4K_YES=1 NVME_4K_KEY_FILE=/tmp/key nvme-4k /dev/nvme0n1 /dev/vdb"

    # --- interrupted after the backup: the NVMe is untouched ---
    machine.succeed(f"NVME_4K_STOP_AFTER=backup {run} >&2")
    assert machine.succeed(f"blockdev --getss {nvme}").strip() == "512"
    machine.succeed("blkid -p /dev/vdb | grep -q NVME4K-BACKUP")

    # --- resumed, interrupted after the format ---
    machine.succeed(f"NVME_4K_STOP_AFTER=format {run} >&2")
    assert machine.succeed(f"blockdev --getss {nvme}").strip() == "4096"

    # --- resumed to the end ---
    out = machine.succeed(f"{run} 2>&1")
    print(out)
    assert "Done" in out, out
    # root ran to the last usable sector of the 512-byte GPT and still fits:
    # that GPT ends it 17408 bytes before the disk's end, 4K ext4 blocks stop
    # 20480 before it, exactly where the 4K GPT ends the partition
    assert "Shrinking the filesystem" not in out, out

    after = ids()
    assert before == after, f"{before} != {after}"
    assert "4096" in machine.succeed(f"cryptsetup luksDump {nvme}p3 | grep sector")
    assert "allow-discards" in machine.succeed(f"cryptsetup luksDump {nvme}p3 | grep Flags")
    machine.succeed(
      f"cryptsetup open --key-file /tmp/key {nvme}p3 new",
      "e2fsck -fn /dev/mapper/new",
      "mount /dev/mapper/new /mnt/root",
      "test \"$(sha256sum /mnt/root/home/zoe/data | cut -d' ' -f1)\" = \"$(cat /tmp/sum)\"",
      "test \"$(stat -c %h /mnt/root/home/zoe/data)\" = 2",
      "test \"$(stat -c %u:%g /mnt/root/home/zoe/data)\" = 1000:100",
      "test \"$(readlink /mnt/root/nix/symlink)\" = ../home/zoe/data",
      "test \"$(getfattr --only-values -n user.test /mnt/root/home/zoe/data)\" = kept",
      "umount /mnt/root && cryptsetup close new",
      "mount /dev/nvme0n1p1 /mnt/esp",
      "grep -q bootloader /mnt/esp/EFI/BOOT/BOOTX64.EFI",
      "umount /mnt/esp",
    )

    # --- running it again changes nothing ---
    out = machine.succeed(f"{run} 2>&1")
    assert "Done" in out, out
    assert ids() == before
  '';
}
