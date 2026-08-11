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
}:
let
  fontconfigBundle = callPackage ./fontconfig.nix { };
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
  ];
}
