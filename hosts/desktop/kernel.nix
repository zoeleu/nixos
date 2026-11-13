# Desktop kernel: Zen (nixpkgs), prebuilt on cache.nixos.org, so nothing is
# compiled in CI or here. Tuned for desktop latency: full preemption,
# 1000 Hz timer, BFQ built in, huge pages only on request (madvise). It keeps
# every cgroup control priorities.nix and ai.nix use to hold the Incus VMs
# back (CPU weight/quota, BFQ IO weights, IO throttling).
# Follows the weekly nixpkgs update. To go back to stock:
#   boot.kernelPackages = pkgs.linuxPackages_latest;
{ pkgs, ... }:

{
  boot.kernelPackages = pkgs.linuxPackages_zen;

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
