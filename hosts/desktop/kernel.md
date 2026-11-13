# Desktop kernel and VM responsiveness

This PC has an i7-8086K (6 cores / 12 threads), 32 GiB RAM, an RX 9060 XT
and a Crucial P3 NVMe system disk.

## Kernel: Zen from nixpkgs

`kernel.nix` uses `pkgs.linuxPackages_zen`. It is prebuilt on
cache.nixos.org, so neither CI nor this PC compiles a kernel, and it follows
the weekly nixpkgs update. Its config: full preemption, 1000 Hz, BFQ built
in (with cgroup IO weights), `madvise` transparent huge pages, sched_ext,
CFS bandwidth control and IO throttling, all of which the VM limits below
rely on.

Compared on 2026-11-12 (nixpkgs pin at the time, all 7.3.4):

| Kernel | Prebuilt | Preemption | HZ |
|---|---|---|---|
| `linuxPackages_zen` (chosen) | cache.nixos.org | full | 1000 |
| `linuxPackages_xanmod_latest` | cache.nixos.org | lazy | 250 |
| `linuxPackages_latest` | cache.nixos.org | lazy | 1000 |
| Chaotic CachyOS (pinned commit, 7.3.0) | no (built in CI for ~4 h) | full | 1000 |

The earlier custom CachyOS build (BORE, ThinLTO, x86-64-v3, AutoFDO
recording) was dropped: no AutoFDO profile was ever recorded, its ccache
was never used, and it cost a ~4-hour CI job per change. Any measurable
gain over Zen was not established for this workload. Its history is in git.

EAC Linux v2 was out of scope: it needs a distro-signed boot chain that
NixOS can't provide. The assessment is in `docs/eac-kernels/`.

## Keeping agents below the desktop

`priorities.nix` puts Incus and its QEMU children in `vms.slice`, with low
CPU/IO weights. All VMs together have a CPU quota of 800% (eight logical
CPUs' time, not pinned or reserved cores), a 10 ms quota period,
16 GiB memory soft limit, 20 GiB hard limit and 4 GiB swap limit. Exceeding
the hard memory limit can kill a VM; size guest RAM and concurrent jobs
accordingly. The system SSD has aggregate VM ceilings of 300 MB/s read,
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
