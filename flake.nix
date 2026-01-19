{
  description = "wl-clipboard-zig";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs =
    {
      self,
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
            inherit (pkgs)
              zls
              pkg-config
              wayland
              wayland-scanner
              wayland-protocols
              clang-tools
              nixd
              nixfmt
              valgrind
              zig-zlint
              ;
          };
        };
      });

      packages = forAllSystems (pkgs: {
        wl-clipboard-zig = pkgs.callPackage ./nix/package.nix { };
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.wl-clipboard-zig;
      });
    };
}
