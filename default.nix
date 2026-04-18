let
  sources = import ./npins;
  flake-compat = import sources.flake-compat;
  zig-flake = (flake-compat { src = sources.zig-overlay; }).defaultNix;
  pkgs = import sources.nixpkgs-unstable {
    overlays = [ zig-flake.overlays.default ];
  };

  zig = pkgs.zigpkgs.master;

  runtimeLibs = with pkgs; [
    libGL
    libglvnd
    wayland
    libxkbcommon
  ];

  allBuildInputs = runtimeLibs ++ (with pkgs; [ wayland-protocols ]);

  filteredSrc = pkgs.lib.fileset.toSource {
    root = ./.;
    fileset = pkgs.lib.fileset.unions [
      ./src
      ./vendor
      ./build.zig
      ./build.zig.zon
    ];
  };

in
pkgs.stdenv.mkDerivation {
  pname = "goop";
  version = "0.0.1";
  src = filteredSrc;

  nativeBuildInputs = with pkgs; [
    zig
    pkg-config
    autoPatchelfHook
  ];

  buildInputs = allBuildInputs;

  buildPhase = ''
    export XDG_CACHE_HOME="$TMPDIR/.cache"
    ln -s ${sources.snail} ../snail
    zig build -Doptimize=ReleaseFast -Dtarget=native-native-gnu
  '';

  installPhase = ''
    mkdir -p $out/lib
    cp zig-out/lib/* $out/lib/
  '';
}
