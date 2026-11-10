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
      mkHost = name: lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          home-manager.nixosModules.home-manager
          ./modules/common.nix
          ./modules/ci.nix
          ./modules/secrets.nix
          ./modules/auto-upgrade.nix
          ./hosts/${name}
          { networking.hostName = lib.mkDefault name; }
        ];
      };
    in
    {
      nixosConfigurations = lib.genAttrs hosts mkHost;

      # Installer ISO (installer/): nix build .#installer-iso
      packages.x86_64-linux.installer-iso = (lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          ./installer
          { nixpkgs.hostPlatform = "x86_64-linux"; }
        ];
      }).config.system.build.isoImage;
    };
}
