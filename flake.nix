{
  description = "NixOS-on-Lima VM for reviewing nixpkgs PRs";

  inputs = {
    # Track nixos-unstable: nixpkgs PRs are based on master, so reviews must be
    # done against unstable rather than a stable release.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Out-of-tree module providing services.lima (lima-init + lima-guestagent).
    # There is no lima guest module in nixpkgs; without this the VM loses its
    # Lima integration (SSH user, mounts, port forwarding) on rebuild.
    nixos-lima = {
      url = "github:nixos-lima/nixos-lima";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, nixos-lima, ... }:
    {
      nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          nixos-lima.nixosModules.lima
          ./configuration.nix
        ];
      };
    };
}
