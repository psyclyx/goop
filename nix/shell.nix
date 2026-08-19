{
  callPackage,
  mkShell,
  lib,
  zig_0_16,
  pkg-config,
  fontconfig,
  libspng,
  libjpeg_turbo,
  libwebp,
  wayland,
  wayland-protocols,
  wayland-scanner,
  libxkbcommon,
  harfbuzz,
  noto-fonts,
  noto-fonts-cjk-sans,
  noto-fonts-color-emoji,
  dejavu_fonts,
  vulkan-headers,
  vulkan-loader,
  shader-slang,
  wgpu-utils,
  skia,
  stdenv,
}:
let
  fontconfigBundle = callPackage ./fontconfig.nix { };

  # The optional Skia backend's C++ shim is compiled by g++ (it shares
  # libskia's libstdc++ ABI); its libstdc++.so.6 must be loadable at runtime.
  gccLib = lib.getLib stdenv.cc.cc;
in
mkShell {
  packages = [
    zig_0_16
    pkg-config
    fontconfig
    libspng
    libjpeg_turbo
    libwebp
    wayland
    wayland-protocols
    wayland-scanner
    libxkbcommon
    harfbuzz
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-color-emoji
    dejavu_fonts
    vulkan-headers
    vulkan-loader
    shader-slang
    wgpu-utils
    skia
  ];

  FONTCONFIG_FILE = "${fontconfigBundle}/fonts.conf";

  LD_LIBRARY_PATH = lib.makeLibraryPath [
    fontconfig
    harfbuzz
    wayland
    libxkbcommon
    vulkan-loader
    libspng
    libjpeg_turbo
    libwebp
    skia
    gccLib
  ];
}
