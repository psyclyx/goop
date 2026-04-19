let
  sources = import ./npins;
  flake-compat = import sources.flake-compat;
  zig-flake = (flake-compat { src = sources.zig-overlay; }).defaultNix;
  pkgs = import sources.nixpkgs-unstable {
    overlays = [ zig-flake.overlays.default ];
  };

  zig = pkgs.zigpkgs."0.16.0";

  runtimeLibs = with pkgs; [
    harfbuzz
    libGL
    libglvnd
    stdenv.cc.cc.lib
    wayland
    libxkbcommon
  ];

  allBuildInputs = runtimeLibs ++ (with pkgs; [ wayland-protocols ]);

  filteredSrc = pkgs.lib.fileset.toSource {
    root = ./.;
    fileset = pkgs.lib.fileset.unions [
      ./src
      ./demo
      ./vendor
      ./build.zig
      ./build.zig.zon
    ];
  };

  common = {
    pname = "goop";
    version = "0.0.1";
    src = filteredSrc;

    nativeBuildInputs = with pkgs; [
      zig
      pkg-config
      autoPatchelfHook
    ];

    buildInputs = allBuildInputs;
  };

  lib = pkgs.stdenv.mkDerivation (common // {
    buildPhase = ''
      export XDG_CACHE_HOME="$TMPDIR/.cache"
      zig build build-lib --fork=${sources.snail} -Doptimize=ReleaseFast
    '';

    installPhase = ''
      mkdir -p $out/lib
      cp zig-out/lib/* $out/lib/
    '';
  });

  demo = pkgs.stdenv.mkDerivation (common // {
    pname = "goop-demo";

    buildPhase = ''
      export XDG_CACHE_HOME="$TMPDIR/.cache"
      zig build build-demo --fork=${sources.snail} -Doptimize=ReleaseFast
    '';

    installPhase = ''
      mkdir -p $out/bin
      cp zig-out/bin/goop-demo $out/bin/goop-demo
    '';
  });

in {
  inherit lib demo;
  default = lib;
}
