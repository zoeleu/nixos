{
  description = "Zoe's NixOS machines";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    jovian = {
      url = "github:Jovian-Experiments/Jovian-NixOS";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Claude Desktop for Linux (repackaged official build). Not following our
    # nixpkgs on purpose: it pins the Electron version the app was built for.
    claude-desktop.url = "github:patrickjaja/claude-desktop-extra";
    # Secrets (secrets/*.yaml) decrypted on each machine with its SSH host key.
    # Pinned to a commit that is at least two weeks old; update deliberately.
    sops-nix = {
      url = "github:Mic92/sops-nix/442449fa7b1fe6c692d0103ac9fc8f9e82931cf3";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v1.2.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Plasma settings (theme, accent colour, wallpaper) from Home Manager
    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    # Declarative disk partitioning, used by the installer ISO
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # Every folder in ./hosts with a hardware-configuration.nix becomes a
  # machine: hosts/<name>/default.nix -> nixosConfigurations.<name>,
  # hostname <name>. CI builds all of them. (A host folder without one is a
  # machine that isn't installed yet.)
  #
  # Rebuild: sudo nixos-rebuild switch --flake /etc/nixos
  #          (picks the config matching this machine's hostname)
  outputs = inputs@{ nixpkgs, home-manager, ... }:
    let
      lib = nixpkgs.lib;
      hosts = lib.attrNames (lib.filterAttrs
        (name: type: type == "directory" && builtins.pathExists ./hosts/${name}/hardware-configuration.nix)
        (builtins.readDir ./hosts));
      # Hosts awaiting installation can opt into CI with an explicit build-only
      # profile. Real generated hardware is still required for deployment.
      ciHosts = lib.attrNames (lib.filterAttrs
        (name: type: type == "directory" && (
          builtins.elem name hosts || builtins.pathExists ./hosts/${name}/ci.nix
        ))
        (builtins.readDir ./hosts));
      mkHost = name: ciBuild: lib.nixosSystem {
        specialArgs = { inherit inputs ciBuild; };
        modules = [
          home-manager.nixosModules.home-manager
          ./modules/common.nix
          ./modules/ci.nix
          ./modules/secrets.nix
          ./modules/auto-upgrade.nix
          ./modules/avatar.nix
          ./modules/branding.nix
          ./modules/os-command.nix
          ./modules/znix.nix
          ./hosts/${name}
          {
            networking.hostName = lib.mkDefault name;
            # the commit a system was built from: `os status`
            system.configurationRevision = inputs.self.rev or inputs.self.dirtyRev or null;
          }
        ] ++ lib.optional ciBuild ./hosts/${name}/ci.nix;
      };
    in
    {
      nixosConfigurations = lib.genAttrs hosts (name: mkHost name false);
      ciConfigurations = lib.genAttrs ciHosts (name:
        mkHost name (!(builtins.elem name hosts)));

      # VM tests:  nix build -L .#checks.x86_64-linux.<name>
      checks.x86_64-linux = let
        test = file: nixpkgs.legacyPackages.x86_64-linux.testers.runNixOSTest {
          imports = [ file ];
          node.specialArgs = { inherit inputs; };
        };
      in {
        touch-unlock = test ./tests/touch-unlock.nix;   # Deck: touch keyboard, then splash
        installer-gui = test ./tests/installer-gui.nix; # installer kiosk + GUI
        nvme-4k = test ./tests/nvme-4k.nix;             # NVMe 512 -> 4K with backup/restore
      };

      # Installer images (installer/), the same installer two ways:
      #   nix build .#installer-iso       USB stick / Ventoy
      #   nix build .#installer-netboot   network boot: bzImage, initrd, netboot.ipxe
      packages.x86_64-linux = let
        desktopPkgs = import nixpkgs {
          system = "x86_64-linux";
          config.allowUnfree = true;
          overlays = [ (import ./overlays/tectonic.nix) (import ./overlays/codex.nix) ];
        };
        installer = module: lib.nixosSystem {
          specialArgs = { inherit inputs; };
          modules = [ module { nixpkgs.hostPlatform = "x86_64-linux"; } ];
        };
        netboot = (installer ./installer/netboot.nix).config.system.build;
      in {
        # Build these before the desktop's generated hardware files exist.
        inherit (desktopPkgs) chatgpt;
        tectonic = desktopPkgs.tectonic-unwrapped;
        install-nixos = import ./installer/package.nix {
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
          inherit inputs;
        };
        nvme-4k = import ./installer/nvme-4k.nix { pkgs = nixpkgs.legacyPackages.x86_64-linux; };
        installer-iso = (installer ./installer/iso.nix).config.system.build.isoImage;
        installer-netboot = nixpkgs.legacyPackages.x86_64-linux.symlinkJoin {
          name = "nixos-zoe-installer-netboot";
          paths = [ netboot.netbootRamdisk netboot.kernel netboot.netbootIpxeScript ];
        };
      };
    };
}
