# Desktop kernel and VM responsiveness

This PC has an i7-8086K (6 cores / 12 threads), 32 GiB RAM, an RX 9060 XT
and a Crucial P3 NVMe system disk.

## Kernel: latest stable from nixpkgs

`kernel.nix` uses `pkgs.linuxPackages_latest`. It is prebuilt on
cache.nixos.org, so neither CI nor this PC compiles a kernel, and it follows
the weekly nixpkgs update. Its config has what the VM limits below rely on:
1000 Hz, BFQ (a module) with cgroup IO weights, `madvise` transparent huge
pages, sched_ext, CFS bandwidth control and IO throttling. Preemption is
lazy by default and can be changed at boot (`preempt=full`).

Compared on 2026-11-12 (nixpkgs pin at the time, all 7.3.4):

| Kernel | Prebuilt | Preemption | HZ |
|---|---|---|---|
| `linuxPackages_latest` (chosen) | cache.nixos.org | lazy | 1000 |
| `linuxPackages_zen` | cache.nixos.org | full | 1000 |
| `linuxPackages_xanmod_latest` | cache.nixos.org | lazy | 250 |
| Chaotic CachyOS (pinned commit, 7.3.0) | no (built in CI for ~4 h) | full | 1000 |

Zen was chosen first and never booted here: 7.3.4-zen1 panics 1.6 s into
the boot, when the initrd loads the USB controller driver (`BUG: kernel
NULL pointer dereference, address: 0000000000000138`, `RIP:
process_one_work+0xb5`, from `tasklet_action`). It is the kernel, not this
PC: QEMU with an emulated USB controller (`-device qemu-xhci`) panics the
same way, with or without `intel_iommu=on`, while stock 7.3.3 and 7.3.4 and
the CachyOS 7.3.0 boot there. Try a new kernel that way before installing
it: boot the built system's `kernel` and `initrd` with `-kernel`/`-initrd`
and wait for "Expecting device /dev/mapper/cryptroot".

`intel_iommu=on` (VT-d, so a PCIe device can't read all RAM over DMA) is
set in `kernel.nix`. It had nothing to do with the panic.

The earlier custom CachyOS build (BORE, ThinLTO, x86-64-v3, AutoFDO
recording) was dropped: no AutoFDO profile was ever recorded, its ccache
was never used, and it cost a ~4-hour CI job per change. Any measurable
gain over the stock kernel was not established for this workload. Its history is in git.

EAC Linux v2 was out of scope: it needs a distro-signed boot chain that
NixOS can't provide.

## Keeping agents below the desktop

`priorities.nix` puts Incus and its QEMU children in `vms.slice`, with low
CPU/IO weights. All VMs together have a CPU quota of 800% (eight logical
CPUs' time, not pinned or reserved cores), a 10 ms quota period,
26 GiB memory soft limit, 28 GiB hard limit and 12 GiB swap limit. Exceeding
the hard memory limit (or 40 GiB of RAM and swap together) can kill a VM;
size guest RAM and concurrent jobs accordingly. The system SSD has aggregate VM ceilings of 300 MB/s read,
150 MB/s write, 20,000 read IOPS and 10,000 write IOPS. These are initial
responsiveness-oriented limits, tunable in that file; other disks are not
bandwidth capped. BFQ weights arbitrate disk contention below the ceilings.
Small host dirty-page limits reduce writeback bursts.

After reboot, verify `systemctl show incus -p ControlGroup` reports
`/vms.slice/incus.service` and that QEMU processes remain beneath it.
Inspect `cpu.stat`, `memory.events` and `io.stat` under
`/sys/fs/cgroup/vms.slice/` during simultaneous builds and gaming. Compare
frame times, dropped frames and CPU/IO/memory pressure, not just average FPS.

Keep `mitigations=auto`. This CPU reports Meltdown, L1TF and MDS exposure;
[the kernel's L1TF documentation](https://www.kernel.org/doc/html/latest/admin-guide/hw-vuln/l1tf.html)
explicitly describes malicious guests accessing host physical memory.
LUKS protects data at rest; its active keys live in host memory. Disabling
all mitigations does not meet the requirement to preserve that boundary.
Default mitigations with SMT enabled also do not guarantee complete
side-channel isolation; this configuration does not claim otherwise.
