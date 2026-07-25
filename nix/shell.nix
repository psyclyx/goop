{
  mkShell,
  lib,
  zig_0_16,
  pkg-config,
  fontconfig,
  wayland,
  wayland-protocols,
  wayland-scanner,
  libxkbcommon,
  harfbuzz,
  noto-fonts,
  dejavu_fonts,
  makeFontsConf,
  vulkan-headers,
  vulkan-loader,
  shader-slang,
  wgpu-utils,
}:
mkShell {
  packages = [
    zig_0_16
    pkg-config
    fontconfig
    wayland
    wayland-protocols
    wayland-scanner
    libxkbcommon
    harfbuzz
    noto-fonts
    dejavu_fonts
    vulkan-headers
    vulkan-loader
    shader-slang
    wgpu-utils
  ];

  FONTCONFIG_FILE = makeFontsConf {
    fontDirectories = [
      noto-fonts
      dejavu_fonts
    ];
  };
  GOOP_DEMO_FONT_PATH = "${dejavu_fonts}/share/fonts/truetype/DejaVuSans.ttf";

  LD_LIBRARY_PATH = lib.makeLibraryPath [
    wayland
    libxkbcommon
    vulkan-loader
  ];
}
