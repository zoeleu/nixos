# Who wins when the machine is overloaded: the desktop first, then apps and
# games, then background work (system services, Nix builds, VMs).
#
# CPU and IO weights only matter under contention (an idle machine gives
# anyone everything), and they only compete between sibling cgroups. IO
# weights work because every disk uses BFQ (default.nix). KWin's
# compositor, output and input threads already run SCHED_RR (its
# CAP_SYS_NICE wrapper), so frames and the cursor survive a busy CPU on their
# own; what can still freeze everything is running out of memory, hence
# MemoryLow for the session and the memory cap on VMs.
#
#   -.slice
#   ├─ user.slice      CPU/IO 400, MemoryLow 2G   (everything zoe runs)
#   │  └─ user-1000.slice / user@1000.service      MemoryLow 2G each
#   │     ├─ session.slice   CPU/IO 1000, MemoryLow 2G  (KWin, plasmashell)
#   │     ├─ app.slice       CPU/IO 100                 (apps Plasma starts)
#   │     │  └─ app-games.slice  CPU/IO 200             (Steam and its games)
#   │     └─ background.slice CPU/IO 30
#   ├─ system.slice    CPU/IO 100 (nix-daemon: batch CPU, idle IO)
#   └─ vms.slice       CPU/IO 20, MemoryHigh 16G     (Incus and its VMs)
#
# Slice names nest by dash: foo-bar.slice lives in foo.slice. Hence
# "vms" (top level) and "app-games" (inside app.slice).
{ lib, ... }:

let
  # MemoryLow only protects a cgroup if every ancestor has at least as much.
  sessionMemory = "2G";
in
{
  # --- System level ---
  systemd.slices.user.sliceConfig = {
    CPUWeight = 400; # default 100
    IOWeight = 400;
    MemoryLow = sessionMemory;
  };
  # user-.slice.d/ applies to every user-<uid>.slice; there's no user-.slice
  # unit to fall back on, so it must be a drop-in
  systemd.slices."user-" = {
    overrideStrategy = "asDropin";
    sliceConfig.MemoryLow = sessionMemory;
  };
  systemd.services."user@".serviceConfig = {
    MemoryLow = sessionMemory;
    # systemd's default delegates cpu, memory, pids; IO weights in the user
    # manager need io too
    Delegate = "cpu io memory pids";
  };

  # Incus (incusd and every VM's QEMU). Its own limits.cpu.priority and
  # limits.disk.priority only apply to containers, so the slice does it.
  # Above MemoryHigh the VMs are throttled and reclaimed (free page reporting
  # hands guest memory back) instead of pushing the desktop into swap.
  systemd.slices.vms = {
    description = "Incus VMs, below the desktop";
    sliceConfig = {
      CPUWeight = 20;
      IOWeight = 20;
      MemoryHigh = "16G";
    };
  };
  systemd.services.incus.serviceConfig.Slice = "vms.slice";

  # Local builds give way to everything else. Most builds come from CI
  # anyway; this keeps an `os update` or a stray compile from stuttering a
  # game. Idle IO means builds wait while anything else uses the disk.
  nix.daemonCPUSchedPolicy = "batch";
  nix.daemonIOSchedClass = "idle";

  # systemd-oomd kills the user cgroup under the most memory pressure (80%
  # for 30 s) before the whole machine thrashes; the session's MemoryLow keeps
  # KWin and plasmashell out of that pressure.
  systemd.oomd.enableUserSlices = true;

  # --- zoe's user manager ---
  systemd.user.slices.session.sliceConfig = {
    CPUWeight = 1000;
    IOWeight = 1000;
    MemoryLow = sessionMemory;
  };
  systemd.user.slices.background.sliceConfig = {
    CPUWeight = 30; # systemd's own default, stated here
    IOWeight = 30;
  };
  systemd.user.slices.app-games = {
    description = "Steam and its games";
    sliceConfig = {
      CPUWeight = 200;
      IOWeight = 200;
    };
  };
  # Plasma starts Steam as app-steam@<id>.service; a drop-in on the template
  # moves it (and every game it launches, being its children) into
  # app-games.slice. Steam started from a terminal stays where it is.
  systemd.user.units."app-steam@.service" = {
    text = ''
      [Service]
      Slice=app-games.slice
    '';
    overrideStrategy = "asDropin";
  };
}
