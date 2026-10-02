# Hinagata's unmanaged workspace outputs. The toolchain, lock, formatter and
# shell remain owned by mori://shinzui/seihou-modules/templates/nix-haskell-flake.
{ inputs, ... }:
{
  perSystem = { pkgs, ... }:
    let
      haskellPackages = pkgs.haskell.packages.ghc9124.override {
        overrides = pkgs.lib.composeExtensions
          (inputs.haskell-nix.lib.haskellExtension pkgs.haskell.lib.compose pkgs)
          (hself: _hsuper: {
            hinagata-core = hself.callCabal2nix "hinagata-core" ./hinagata-core { };
          });
      };
    in
    {
      packages.hinagata-core = haskellPackages.hinagata-core;
      packages.default = haskellPackages.hinagata-core;
      checks.hinagata-core = haskellPackages.hinagata-core;
    };
}
