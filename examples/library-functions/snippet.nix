let
  lib = (import ./lib { inherit inputs; lib = nixpkgs.lib; });
  catalog = lib.discoverCatalog sources;
  selection = lib.selectSkills {
    inherit catalog sources;
    allowlist = [ "foo" ];
    skills = { bar = { from = "local"; path = "bar"; }; };
  };
  bundle = lib.mkBundle {
    pkgs = nixpkgs.legacyPackages.${system};
    selection = selection;
  };
in
{
  inherit catalog selection bundle;
}
