# Hinagata's unmanaged workspace outputs. The toolchain, lock, formatter and
# shell remain owned by mori://shinzui/seihou-modules/templates/nix-haskell-flake.
{ inputs, ... }:
{
  perSystem = { pkgs, self', ... }:
    let
      gitHash = inputs.self.shortRev or (inputs.self.dirtyShortRev or "unknown");
      haskellPackages = pkgs.haskell.packages.ghc9124.override {
        overrides = pkgs.lib.composeExtensions
          (inputs.haskell-nix.lib.haskellExtension pkgs.haskell.lib.compose pkgs)
          (hself: _hsuper: {
            hinagata-core = hself.callCabal2nix "hinagata-core" ./hinagata-core { };
            hinagata-postgres = hself.callCabal2nix "hinagata-postgres" ./hinagata-postgres { };
            hinagata-cli = hself.callCabal2nix "hinagata-cli" ./hinagata-cli { };
            hinagata-workbench-example = hself.callCabal2nix "hinagata-workbench-example" ./examples/workbench { };
          });
      };
    in
    {
      packages.hinagata-core = haskellPackages.hinagata-core;
      packages.hinagata-postgres = haskellPackages.hinagata-postgres;
      packages.hinagata-workbench-example = haskellPackages.hinagata-workbench-example;
      packages.hinagata-cli = pkgs.haskell.lib.overrideCabal haskellPackages.hinagata-cli (old: {
        configureFlags = (old.configureFlags or [ ]) ++ [
          "--ghc-option=-DGIT_HASH=\"${gitHash}\""
        ];
      });
      packages.default = self'.packages.hinagata-cli;
      apps.default = {
        type = "app";
        program = "${self'.packages.hinagata-cli}/bin/hinagata";
      };
      checks.hinagata-core = haskellPackages.hinagata-core;
      checks.hinagata-postgres = haskellPackages.hinagata-postgres;
      checks.hinagata-workbench-example = haskellPackages.hinagata-workbench-example;
      checks.hinagata-cli = self'.packages.hinagata-cli;
      haskellProject.extraDevPackages = [ pkgs.hurl pkgs.dhall pkgs.curl ];
    };
}
