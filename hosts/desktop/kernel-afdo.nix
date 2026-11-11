# Kernel AutoFDO profiles, recorded on this PC while it does real work.
#
#   kernel-afdo start <workload>   record kernel branch samples (gaming, build, ...)
#   kernel-afdo stop <workload>    stop; the data is converted in the background
#   kernel-afdo status             what's recording, what's waiting, what's done
#   kernel-afdo merge [-o FILE]    weighted merge -> hosts/desktop/kernel.afdo
#
# GameMode starts and stops the "gaming" workload by itself, and
# kernel-afdo-vm-watch.service records "vm-build" while Incus VMs (AI agents
# compiling) keep the CPU busy; nothing inside a VM can start or steer it.
# Anything running as zoe may start/stop recordings (polkit rule below); that
# gives nothing new, since zoe has passwordless sudo here anyway.
#
# Recording refuses to start while more than spoolLimitGB of raw data waits
# for conversion, so busy days can't fill the disk.
#
# How it works: kernel-afdo-record@<workload>.service runs `perf record`
# with LBR branch stacks (-b), kernel branches only (:k), into 10-minute
# chunks under /var/lib/kernel-afdo/spool. Raw perf data is ~2 GB/hour, so
# kernel-afdo-convert.service turns each finished chunk into a small sample
# profile (llvm-profgen --kernel) at idle priority and deletes it.
# llvm-profgen needs the exact vmlinux (with DWARF) that was running, so the
# system links it at /run/booted-system/kernel-vmlinux, and a GC root keeps
# it while its chunks wait for conversion.
#
# The profile only reaches the build when it's committed: `kernel-afdo
# merge`, then commit hosts/desktop/kernel.afdo (default.nix passes it to the
# kernel build). A new profile means a full kernel rebuild in CI, so refresh
# it together with chaotic bumps, which rebuild the kernel anyway.
{ config, lib, pkgs, ... }:

let
  # Relative weights for `merge`; samples are multiplied by these. Workloads
  # not listed get 1. Gaming is what this PC is tuned for.
  weights = {
    gaming = 3;
    build = 1;
    vm-build = 1;
  };

  stateDir = "/var/lib/kernel-afdo";
  spoolLimitGB = 20;

  # vm-watch: Incus runs every VM's QEMU (and its vhost threads) in
  # incus.service's cgroup (looked up from systemd, so moving incus to
  # another slice doesn't break it). Start "vm-build" after a minute above
  # vmBusyCores, stop it after three minutes below vmIdleCores. Checked
  # every 30 s.
  vmBusyCores = 2;
  vmIdleCores = 0.5;

  kernel-afdo = pkgs.writeShellApplication {
    name = "kernel-afdo";
    runtimeInputs = with pkgs; [
      perf
      llvmPackages.llvm # llvm-profgen, llvm-profdata
      coreutils
      findutils
      gnugrep
      systemd
      util-linux # flock
    ];
    text = ''
      state=${stateDir}
      weights=/etc/kernel-afdo/weights

      usage() {
        cat <<'EOF'
      Usage: kernel-afdo start|stop <workload>
             kernel-afdo status
             kernel-afdo merge [-o FILE] [--all]
      Workload names: lowercase letters, digits and dashes (gaming, build, ...).
      merge uses the running kernel's version unless --all; default output is
      /etc/nixos/hosts/desktop/kernel.afdo.
      EOF
      }

      check_name() {
        if [[ ! "$1" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]]; then
          echo "kernel-afdo: bad workload name '$1'" >&2
          exit 2
        fi
      }

      # "<kernel version>-<first 8 chars of the vmlinux store hash>"
      kernel_id() {
        local v store
        v=$(readlink -e "$1")
        store=''${v#/nix/store/}
        echo "$(uname -r)-''${store:0:8}"
      }

      spool_full() {
        local kb
        kb=$(du -sk "$state/spool" 2>/dev/null | cut -f1 || true)
        (( ''${kb:-0} > ${toString spoolLimitGB} * 1024 * 1024 ))
      }

      recording() {
        systemctl is-active --quiet "kernel-afdo-record@$1.service"
      }

      cmd=''${1:-}
      shift || true
      case "$cmd" in
        start | stop)
          [[ $# -eq 1 ]] || { usage >&2; exit 2; }
          check_name "$1"
          exec systemctl "$cmd" --no-block "kernel-afdo-record@$1.service"
          ;;

        record) # ExecStart of kernel-afdo-record@.service (root)
          check_name "$1"
          vmlinux=$(readlink -e /run/booted-system/kernel-vmlinux) || {
            echo "no /run/booted-system/kernel-vmlinux: boot a generation built with kernel-afdo.nix" >&2
            exit 1
          }
          if spool_full; then
            echo "not recording '$1': over ${toString spoolLimitGB} GB waits for conversion" >&2
            exit 1
          fi
          id=$(kernel_id "$vmlinux")
          dir=$state/spool/$id
          mkdir -p "$dir/$1" /nix/var/nix/gcroots/kernel-afdo
          ln -sfn "$vmlinux" "$dir/vmlinux"
          # keep this kernel's vmlinux until its chunks are converted
          ln -sfn "''${vmlinux%%/lib/*}" "/nix/var/nix/gcroots/kernel-afdo/$id"
          echo "recording '$1' on kernel $id"
          exec perf record -e BR_INST_RETIRED.NEAR_TAKEN:k -a -N -b -c 500009 \
            --switch-output=10m -o "$dir/$1/perf.data"
          ;;

        convert) # kernel-afdo-convert.service (root, idle priority)
          exec 9>"$state/convert.lock"
          flock -n 9 || exit 0
          shopt -s nullglob
          for kdir in "$state"/spool/*/; do
            id=$(basename "$kdir")
            for chunk in "$kdir"*/perf.data.*; do
              workload=$(basename "$(dirname "$chunk")")
              out=$state/profiles/$id/$workload
              mkdir -p "$out"
              name=$(basename "$chunk")
              if [[ ! -e "$kdir/vmlinux" ]]; then
                echo "dropping $chunk: vmlinux for $id is gone" >&2
              elif llvm-profgen --kernel --binary="$kdir/vmlinux" --perfdata="$chunk" \
                     --output="$out/.''${name#perf.data.}.tmp" 2>"$out/.log"; then
                mv "$out/.''${name#perf.data.}.tmp" "$out/''${name#perf.data.}.afdo"
                echo "converted $id/$workload/''${name#perf.data.}"
              else
                echo "llvm-profgen failed on $chunk:" >&2
                tail -n 5 "$out/.log" >&2
              fi
              rm -f "$chunk" "$out/.log"
            done
            # done with a kernel once nothing waits and nothing records on it
            if [[ "$id" != "$(kernel_id /run/booted-system/kernel-vmlinux 2>/dev/null || true)" ]] &&
               [[ -z "$(find "$kdir" -name 'perf.data*' -print -quit)" ]]; then
              rm -rf "$kdir" "/nix/var/nix/gcroots/kernel-afdo/$id"
            fi
          done
          ;;

        vm-watch) # kernel-afdo-vm-watch.service (root)
          cpu_usec() {
            local key value cg
            cg=$(systemctl show -P ControlGroup incus.service 2>/dev/null || true)
            if [[ -n $cg && -r /sys/fs/cgroup$cg/cpu.stat ]]; then
              while read -r key value; do
                [[ $key == usage_usec ]] && { echo "$value"; return; }
              done < "/sys/fs/cgroup$cg/cpu.stat"
            fi
            echo 0
          }
          interval=30 busy=0 idle=0 mine=0
          prev=$(cpu_usec)
          while sleep "$interval"; do
            now=$(cpu_usec)
            milli=$(( (now - prev) / (interval * 1000) )) # thousandths of a core
            prev=$now
            # a game records "gaming" already; two LBR sessions would count twice
            if recording gaming; then
              if (( mine )) && recording vm-build; then
                systemctl stop --no-block kernel-afdo-record@vm-build.service
                echo "game started: pausing vm-build"
              fi
              mine=0 busy=0 idle=0
              continue
            fi
            if (( milli >= ${toString (vmBusyCores * 1000)} )); then busy=$((busy + 1)); else busy=0; fi
            if (( milli < ${toString (builtins.floor (vmIdleCores * 1000))} )); then idle=$((idle + 1)); else idle=0; fi
            if (( busy >= 2 )) && ! recording vm-build && ! spool_full; then
              systemctl start --no-block kernel-afdo-record@vm-build.service
              mine=1
              echo "VMs busy ($((milli / 1000)).$(( milli % 1000 / 100 )) cores): recording vm-build"
            elif (( mine && idle >= 6 )) && recording vm-build; then
              systemctl stop --no-block kernel-afdo-record@vm-build.service
              mine=0
              echo "VMs idle: stopped vm-build"
            fi
          done
          ;;

        status)
          systemctl list-units --no-legend --plain 'kernel-afdo-record@*' || true
          echo "waiting for conversion: $(du -sh "$state/spool" 2>/dev/null | cut -f1 || echo 0)"
          if [[ -d "$state/profiles" ]]; then
            for d in "$state"/profiles/*/*/; do
              [[ -d "$d" ]] || continue
              printf '%-40s %4s chunks\n' "''${d#"$state"/profiles/}" "$(find "$d" -name '*.afdo' | wc -l)"
            done
          fi
          ;;

        merge)
          output=/etc/nixos/hosts/desktop/kernel.afdo
          prefix="$(uname -r)-"
          while [[ $# -gt 0 ]]; do
            case "$1" in
              -o) output=$2; shift 2 ;;
              --all) prefix=; shift ;;
              *) usage >&2; exit 2 ;;
            esac
          done
          tmp=$(mktemp -d)
          trap 'rm -rf "$tmp"' EXIT
          shopt -s nullglob
          declare -A files=()
          for f in "$state"/profiles/"$prefix"*/*/*.afdo; do
            w=$(basename "$(dirname "$f")")
            files[$w]+="$f"$'\n'
          done
          if [[ ''${#files[@]} -eq 0 ]]; then
            echo "kernel-afdo: no profiles for kernel ${prefix:-any}* yet" >&2
            exit 1
          fi
          args=()
          for w in "''${!files[@]}"; do
            mapfile -t list < <(printf '%s' "''${files[$w]}")
            llvm-profdata merge --sample --extbinary -o "$tmp/$w.afdo" "''${list[@]}"
            weight=$(grep -m1 "^$w " "$weights" | cut -d' ' -f2 || true)
            args+=("--weighted-input=''${weight:-1},$tmp/$w.afdo")
            echo "$w: ''${#list[@]} chunks, weight ''${weight:-1}"
          done
          llvm-profdata merge --sample --extbinary -o "$output" "''${args[@]}"
          echo "wrote $output; commit it to build the kernel with it"
          ;;

        *) usage >&2; exit 2 ;;
      esac
    '';
  };
in
{
  environment.systemPackages = [ kernel-afdo ];

  environment.etc."kernel-afdo/weights".text =
    lib.concatStrings (lib.mapAttrsToList (w: n: "${w} ${toString n}\n") weights);

  # The running kernel's vmlinux (with DWARF), which llvm-profgen needs:
  # /run/booted-system/kernel-vmlinux. Adds the kernel's dev output (~800 MB)
  # to every generation.
  system.systemBuilderCommands = ''
    ln -s ${config.boot.kernelPackages.kernel.dev}/vmlinux $out/kernel-vmlinux
  '';

  systemd.services."kernel-afdo-record@" = {
    description = "Kernel AutoFDO recording (%i)";
    serviceConfig = {
      ExecStart = "${kernel-afdo}/bin/kernel-afdo record %i";
      ExecStopPost = "${pkgs.systemd}/bin/systemctl start --no-block kernel-afdo-convert.service";
      KillSignal = "SIGINT"; # perf writes out the last chunk
      TimeoutStopSec = 60;
      RuntimeMaxSec = "8h"; # a forgotten `start` doesn't fill the disk
      StateDirectory = "kernel-afdo";
      StateDirectoryMode = "0755";
      UMask = "0022";
    };
  };

  systemd.services.kernel-afdo-convert = {
    description = "Convert kernel AutoFDO recordings to profiles";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${kernel-afdo}/bin/kernel-afdo convert";
      StateDirectory = "kernel-afdo";
      StateDirectoryMode = "0755";
      UMask = "0022";
      # spare cycles only: never slows a game down
      Nice = 19;
      CPUSchedulingPolicy = "idle";
      IOSchedulingClass = "idle";
    };
  };

  systemd.services.kernel-afdo-vm-watch = {
    description = "Record kernel AutoFDO profiles while Incus VMs are busy";
    wantedBy = [ "multi-user.target" ];
    after = [ "incus.service" ];
    serviceConfig = {
      ExecStart = "${kernel-afdo}/bin/kernel-afdo vm-watch";
      Restart = "always";
      RestartSec = 30;
    };
  };

  # finished 10-minute chunks get converted while recording continues
  systemd.timers.kernel-afdo-convert = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitInactiveSec = "10min";
    };
  };

  # zoe (and so GameMode, which runs as zoe) may start/stop recordings
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id == "org.freedesktop.systemd1.manage-units" &&
          subject.user == "zoe" &&
          /^kernel-afdo-record@[a-z0-9-]+\.service$/.test(action.lookup("unit")) &&
          (action.lookup("verb") == "start" || action.lookup("verb") == "stop")) {
        return polkit.Result.YES;
      }
    });
  '';

  programs.gamemode.settings.custom = {
    start = "${kernel-afdo}/bin/kernel-afdo start gaming";
    end = "${kernel-afdo}/bin/kernel-afdo stop gaming";
  };
}
