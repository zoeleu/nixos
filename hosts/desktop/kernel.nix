# Desktop kernel: the latest stable kernel from nixpkgs, prebuilt on
# cache.nixos.org, so nothing is compiled in CI or here. It follows the
# weekly nixpkgs update.
#
# Not Zen: linuxPackages_zen 7.3.4-zen1 panics on this PC while the initrd
# loads the USB controller driver (NULL pointer in process_one_work, 1.6 s
# into the boot). Before trying another kernel, boot it in QEMU with a USB
# controller first (kernel.md); the stock 7.3.3 and 7.3.4 pass that.
{ pkgs, ... }:

{
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Keep mitigations=auto: L1TF/MDS on this CPU (i7-8086K, Coffee Lake) can
  # cross the VM/host boundary, and the LUKS key is in host memory while the
  # disk is open.
  boot.kernelParams = [
    "mitigations=auto"
    # VT-d is on in the firmware (DMAR table) but the kernel leaves it off
    # unless asked. With it, a PCIe/M.2 device can only reach memory mapped
    # for it, instead of reading all RAM (and the LUKS key) over DMA.
    "intel_iommu=on"
  ];

  # Small writeback batches reduce stalls when VM builds dirty host pages.
  boot.kernel.sysctl = {
    "vm.dirty_background_bytes" = 64 * 1024 * 1024;
    "vm.dirty_bytes" = 256 * 1024 * 1024;
  };
}
