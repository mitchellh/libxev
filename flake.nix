{
  description = "libxev is a high performance, cross-platform event loop.";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-25.05/nixexprs.tar.xz";
    flake-utils.url = "github:numtide/flake-utils";
    zig.url = "github:mitchellh/zig-overlay";

    # Used for shell.nix
    flake-compat = {
      url = github:edolstra/flake-compat;
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    ...
  } @ inputs: let
    overlays = [
      # Other overlays
      (final: prev: rec {
        zigpkgs = inputs.zig.packages.${prev.system};
        zig = inputs.zig.packages.${prev.system}."0.15.2";

        # Our package
        libxev = prev.callPackage ./nix/package.nix {};
      })
    ];

    # Our supported systems are the same supported systems as the Zig binaries
    systems = builtins.attrNames inputs.zig.packages;
  in
    flake-utils.lib.eachSystem systems (
      system: let
        pkgs = import nixpkgs {inherit overlays system;};
      in rec {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            mandoc
            scdoc
            zig

            # Wasm
            wabt
            wasmtime
            wasmer

            # Website
            nodejs
          ];
        };

        # For compatibility with older versions of the `nix` binary
        devShell = self.devShells.${system}.default;

        # Our package
        packages.libxev = pkgs.libxev;
        defaultPackage = packages.libxev;
      }
    );
}
