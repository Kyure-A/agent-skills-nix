{
  description = "Declarative Agent Skills management with flake-pinned sources and Home Manager integration";

  inputs = {
    blueprint = {
      url = "github:numtide/blueprint";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs:
    let
      blueprint = inputs.blueprint {
        inherit inputs;
        prefix = "nix";
        systems = import ./nix/systems.nix;
      };
    in
    import ./nix/flake-outputs.nix { inherit blueprint inputs; };
}
