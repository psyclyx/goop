{
  lib,
  stdenv,
  linkFarm,
  makeWrapper,
  zig_0_16,
  pkg-config,
  harfbuzz,
  libxkbcommon,
  wayland,
  wayland-protocols,
  vulkan-headers,
  vulkan-loader,
  shader-slang,
  wgpu-utils,
  dejavu_fonts,
}:
let
  npins = import ../../npins;

  deps = linkFarm "zig-packages" [
    {
      name = "snail-0.18.0-vw75SM3UBAGPYcgh5xd_lc_la4cJp8xNnAPyVLHAWpWv";
      path = npins.snail;
    }
  ];

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../src
      ../../demo
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
    harfbuzz
    libxkbcommon
    wayland
    wayland-protocols
    vulkan-headers
    vulkan-loader
  ];

  zigBuildFlags = [
    "--system"
    "${deps}"
  ];

  postFixup = ''
    wrapProgram "$out/bin/goop-file-manager-demo" \
      --set-default GOOP_DEMO_FONT_PATH "${dejavu_fonts}/share/fonts/truetype/DejaVuSans.ttf"
  '';
}
