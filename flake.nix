{
  description = "Zoe's NixOS Flake";

  inputs = {
    # NixOS official package source, using the nixos-25.11 branch here
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    home-manager.url = "github:nix-community/home-manager/release-25.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, rust-overlay, home-manager, ... }@inputs: {
    nixosConfigurations.desktop = nixpkgs.lib.nixosSystem {
      modules = [
        # Import the previous configuration.nix we used,
        # so the old configuration file still takes effect
        ./configuration.nix
        home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.zoe = ./home.nix;
          }

        ({ pkgs, ... }: {
          nixpkgs.overlays = [ rust-overlay.overlays.default ];
          environment.systemPackages = [ pkgs.rust-bin.stable.latest.default ];
        })

      ];
    };
  };
}
