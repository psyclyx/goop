{
  callPackage,
  lib,
  stdenv,
  linkFarm,
  makeWrapper,
  zig_0_16,
  pkg-config,
  fontconfig,
  libspng,
  libjpeg_turbo,
  libwebp,
  harfbuzz,
  libxkbcommon,
  wayland,
  wayland-protocols,
  vulkan-headers,
  vulkan-loader,
  shader-slang,
  wgpu-utils,
  dejavu_fonts,
  noto-fonts,
  noto-fonts-cjk-sans,
  noto-fonts-color-emoji,
}:
let
  npins = import ../../npins;
  fontconfigBundle = callPackage ../fontconfig.nix { };

  deps = linkFarm "zig-packages" [
    {
      name = "snail-0.19.0-vw75SJ_2BAEaJX7P0tjMgAKYdyhkURJdS7oJUuKjZlHE";
      path = npins.snail;
    }
  ];

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../src
      ../../demo
      ../../examples
      ../../include
      ../../vendor
      ../../build.zig
      ../../build.zig.zon
    ];
  };
in
stdenv.mkDerivation {
  pname = "goop";
  version = "0.0.1";
  inherit src;

  strictDeps = true;

  nativeBuildInputs = [
    zig_0_16
    pkg-config
    shader-slang
    wgpu-utils
    makeWrapper
  ];

  buildInputs = [
    fontconfig
    libspng
    libjpeg_turbo
    libwebp
    harfbuzz
    libxkbcommon
    wayland
    wayland-protocols
    vulkan-headers
    vulkan-loader
    dejavu_fonts
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-color-emoji
  ];

  FONTCONFIG_FILE = "${fontconfigBundle}/fonts.conf";
  LD_LIBRARY_PATH = lib.makeLibraryPath [
    fontconfig
    libspng
    libjpeg_turbo
    libwebp
    harfbuzz
    libxkbcommon
    wayland
    vulkan-loader
  ];

  zigBuildFlags = [
    "--system"
    "${deps}"
  ];

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    export XDG_CACHE_HOME="$TMPDIR/xdg-cache"
    zig build test --system ${deps} -Dcpu=baseline --release=safe
    runHook postCheck
  '';

  postFixup = ''
    for executable in goop-demo goop-file-manager-demo; do
      wrapProgram "$out/bin/$executable" \
        --set-default FONTCONFIG_FILE "${fontconfigBundle}/fonts.conf"
    done
  '';
}
