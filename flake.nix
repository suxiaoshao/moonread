{
  description = "Moonread development environment";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.xz";
    rust-overlay = {
      url = "git+https://github.com/oxalica/rust-overlay?shallow=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, rust-overlay, ... }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        };
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          rust =
            (pkgs.rust-bin.stable.latest.minimal.override {
              extensions = [
                "clippy"
                "rustfmt"
              ];
              targets = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
                "aarch64-apple-ios"
                "aarch64-apple-ios-sim"
                "x86_64-apple-ios"
              ];
            }).overrideAttrs
              (
                _:
                pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
                  # rust-overlay otherwise propagates Nix's macOS compiler and
                  # target libraries even when the shell uses stdenvNoCC.
                  depsHostHostPropagated = [ ];
                  propagatedBuildInputs = [ ];
                  depsTargetTargetPropagated = [ ];
                }
              );
          # Xcode owns the Apple SDK and linker. Do not shadow them with
          # Nix's macOS-only SDK or compiler wrappers in the iOS environment.
          mkShell = if pkgs.stdenv.hostPlatform.isDarwin then pkgs.mkShellNoCC else pkgs.mkShell;
        in
        {
          default = mkShell {
            packages = [
              rust
              pkgs.nixfmt
              pkgs.actionlint
              pkgs.gitleaks
              pkgs.zola
            ];
          };
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);
    };
}
