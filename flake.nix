{
  description = "wl-clipboard-zig";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    tree_magic.url = "github:r0chd/tree_magic";
  };
  outputs =
    {
      self,
      tree_magic,
      nixpkgs,
      zig,
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
            inherit (zig.packages.${pkgs.stdenv.hostPlatform.system}) "0.15.2";
            inherit (tree_magic.packages.${pkgs.stdenv.hostPlatform.system}) tree_magic_mini;
            inherit (pkgs)
              zls
              pkg-config
              wayland
              wayland-scanner
              wayland-protocols
              clang-tools
              nixd
              nixfmt-rfc-style
              valgrind
              zig-zlint
              ;
          };
        };
      });

      packages = forAllSystems (pkgs: {
        wl-clipboard-zig = pkgs.callPackage ./nix/package.nix {
          inherit (tree_magic.packages.${pkgs.stdenv.hostPlatform.system}) tree_magic_mini;
        };
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.wl-clipboard-zig;
      });
    };
}
