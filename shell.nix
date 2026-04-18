let
  sources = import ./npins;
  flake-compat = import sources.flake-compat;
  zig-flake = (flake-compat { src = sources.zig-overlay; }).defaultNix;
  pkgs = import sources.nixpkgs-unstable {
    overlays = [ zig-flake.overlays.default ];
  };
in
pkgs.mkShell {
  packages = with pkgs; [
    zigpkgs.master
    pkg-config
    libGL
    libglvnd
    wayland
    wayland-protocols
    wayland-scanner
    libxkbcommon
  ];

  LD_LIBRARY_PATH = with pkgs; pkgs.lib.makeLibraryPath [
    libGL
    libglvnd
    wayland
    libxkbcommon
  ];
}
