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
  };

  # Every folder in ./hosts becomes a machine: hosts/<name>/default.nix
  # -> nixosConfigurations.<name>, hostname <name>. CI builds all of them.
  #
  # Rebuild: sudo nixos-rebuild switch --flake /etc/nixos
  #          (picks the config matching this machine's hostname)
  outputs = inputs@{ nixpkgs, home-manager, ... }:
    let
      lib = nixpkgs.lib;
      hosts = lib.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./hosts));
      mkHost = name: lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          home-manager.nixosModules.home-manager
          ./modules/common.nix
          ./hosts/${name}
          { networking.hostName = lib.mkDefault name; }
        ];
      };
    in
    {
      nixosConfigurations = lib.genAttrs hosts mkHost;
    };
}
