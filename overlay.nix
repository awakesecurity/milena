{ gitignore, ghc }:

final: prev: {
  haskell = prev.haskell // {
    packages = prev.haskell.packages // {
      "${ghc}" = prev.haskell.packages."${ghc}".override (old: {
        overrides = hfinal: _: {
          milena = hfinal.callCabal2nix "milena" (gitignore.lib.gitignoreSource ./.) { };
        };
      });
    };
  };

  milena-dev-shell =
    let
      hsPkgs = final.haskell.packages.${ghc};
    in
      hsPkgs.shellFor {
        name = "milena";

        buildInputs = [
          final.cabal-install
          final.haskell-language-server
        ];

        packages = pkgs: [pkgs.milena];
      };
}