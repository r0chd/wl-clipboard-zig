{
  lib,
  stdenv,
  wayland,
  wayland-scanner,
  wayland-protocols,
  zig,
  pkg-config,
  callPackage,
  tree_magic_mini,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "wl-clipboard-zig";
  version = "0.1.0";

  src = ./..;

  dontConfigure = true;
  doCheck = false;

  nativeBuildInputs = [
    zig.hook
    wayland-scanner
    pkg-config
    wayland-protocols
  ];

  buildInputs = [
    wayland
    tree_magic_mini
  ];

  zigBuildFlags = [ "--release=fast" ];

  postPatch = ''
    ln -s ${callPackage ./deps.nix { }} $ZIG_GLOBAL_CACHE_DIR/p
  '';

  meta = {
    description = "";
    homepage = "https://forgejo.r0chd.pl/r0chd/wl-clipboard-zig";
    license = lib.licenses.mit;
    maintainers = [ lib.maintainers.r0chd ];
    platforms = lib.platforms.linux;
  };
})
