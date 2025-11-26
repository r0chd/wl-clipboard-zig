{
  description = "wl-clipboard-zig";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zls = {
      url = "github:zigtools/zls";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.zig-overlay.follows = "zig";
    };
    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs =
    {
      nixpkgs,
      zig,
      zls,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems =
        function: nixpkgs.lib.genAttrs systems (system: function nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = builtins.attrValues {
            inherit (zig.packages.${pkgs.stdenv.hostPlatform.system}) "0.15.1";
            inherit (zls.packages.${pkgs.stdenv.hostPlatform.system}) default;
            inherit (pkgs)
              pkg-config
              wayland
              wayland-scanner
              wayland-protocols
              wayland-utils
              clang-tools
              nixd
              nixfmt-rfc-style
              valgrind
              ;
          };
        };
      });

      packages = forAllSystems (pkgs: {
        default = pkgs.callPackage ./nix/package.nix { };
      });
    };
}
