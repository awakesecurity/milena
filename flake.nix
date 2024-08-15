{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/24.05";
    flake-utils.url = "github:numtide/flake-utils";
    gitignore = {
      url = "github:hercules-ci/gitignore.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, gitignore }:
    flake-utils.lib.eachSystem ["x86_64-linux" "x86_64-darwin"] (system:
      let
        ghc = "ghc94";

        haskellOverlay = import ./overlay.nix {
          inherit gitignore ghc;
        };

        pkgs = import nixpkgs {
          inherit system;
          overlays = [ haskellOverlay ];
        };
      in {
        packages.default = pkgs.haskell.packages.${ghc}.milena;
        devShells.default = pkgs.milena-dev-shell;
      });
}
