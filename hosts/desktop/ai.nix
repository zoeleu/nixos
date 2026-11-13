# Local LLMs on the RX 9060 XT (RDNA 4, gfx1200): Ollama, llama.cpp and
# LM Studio, plus the ROCm drivers and tools.
#
# Vulkan (Mesa's RADV) is the default backend: the plain `ollama` service
# and `llama-*` commands use it. ROCm builds sit next to them:
#   llama-server-rocm, llama-cli-rocm, ...   llama.cpp's commands, ROCm build
#   ollama-rocm serve                         second Ollama on 127.0.0.1:11435
#                                             (models in ~/.ollama), then
#                                             `ollama-rocm run <model>`
# LM Studio picks its runtime (Vulkan or ROCm llama.cpp) in its own settings.
# nixpkgs' ROCm already targets gfx1200, so no HSA_OVERRIDE_GFX_VERSION.
{ lib, pkgs, ... }:

let
  # Prebuilt ROCm programs (PyTorch wheels, LM Studio's ROCm runtime, ...)
  # look for the libraries in /opt/rocm, which NixOS doesn't have
  rocmEnv = pkgs.symlinkJoin {
    name = "rocm-combined";
    paths = with pkgs.rocmPackages; [ clr hipblas rocblas rocminfo rocm-smi ];
  };

  # Every bin/<name> of the ROCm llama.cpp as bin/<name>-rocm, so it doesn't
  # collide with the Vulkan build
  llama-cpp-rocm = pkgs.runCommand "llama-cpp-rocm-suffixed" { } ''
    mkdir -p $out/bin
    for f in ${pkgs.llama-cpp-rocm}/bin/*; do
      ln -s "$f" "$out/bin/$(basename "$f")-rocm"
    done
  '';

  # ROCm Ollama on its own port, so it can run beside the Vulkan service
  ollama-rocm = pkgs.runCommand "ollama-rocm-wrapped" {
    nativeBuildInputs = [ pkgs.makeWrapper ];
  } ''
    makeWrapper ${lib.getExe pkgs.ollama-rocm} $out/bin/ollama-rocm \
      --set-default OLLAMA_HOST 127.0.0.1:11435
  '';
in
{
  # ROCm OpenCL (clinfo, Blender, Darktable...) next to Mesa's Vulkan
  hardware.amdgpu.opencl.enable = true;
  systemd.tmpfiles.rules = [ "L+ /opt/rocm - - - - ${rocmEnv}" ];

  # /dev/kfd and /dev/dri/renderD* for ROCm programs zoe runs herself
  users.users.zoe.extraGroups = [ "render" "video" ];

  # Ollama API on 127.0.0.1:11434 (Vulkan); models live in /var/lib/ollama.
  # Also puts the `ollama` client on the PATH.
  services.ollama = {
    enable = true;
    package = pkgs.ollama-vulkan;
  };

  environment.systemPackages = with pkgs; [
    llama-cpp-vulkan # llama-cli, llama-server, ...
    llama-cpp-rocm   # the same, suffixed -rocm (above)
    ollama-rocm
    lmstudio
    vulkan-tools     # vulkaninfo
    clinfo
    rocmPackages.rocminfo
    rocmPackages.rocm-smi
    amdgpu_top       # GPU/VRAM usage per process
  ];
}
