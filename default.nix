let
  sources = import ./npins;
  pkgs = import sources.nixpkgs-unstable {};
  zig = pkgs.zig_0_16;
  deps = pkgs.linkFarm "zig-packages" [
    {
      name = "snail-0.4.1-vw75SE6UagBhwNwI3IRNOn1i9ehrmDJLcPup7TXS_91C";
      path = sources.snail;
    }
  ];

  src = pkgs.lib.fileset.toSource {
    root = ./.;
    fileset = pkgs.lib.fileset.unions [
      ./src
      ./demo
      ./include
      ./vendor
      ./build.zig
      ./build.zig.zon
    ];
  };

  goop = pkgs.stdenv.mkDerivation {
    pname = "goop";
    version = "0.0.1";
    inherit src;

    strictDeps = true;

    nativeBuildInputs = [
      zig
      pkgs.pkg-config
    ];

    buildInputs = with pkgs; [
      harfbuzz
      libGL
      libglvnd
      libxkbcommon
      wayland
      wayland-protocols
    ];

    zigBuildFlags = [
      "--system"
      "${deps}"
    ];
  };

in {
  inherit goop;
  lib = goop;
  demo = goop;
  default = goop;
}
