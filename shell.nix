let
  sources = import ./npins;
  flake-compat = import sources.flake-compat;
  zig-flake = (flake-compat {src = sources.zig-overlay;}).defaultNix;
  pkgs = import sources.nixpkgs-unstable {
    overlays = [zig-flake.overlays.default];
  };
in
  pkgs.mkShell {
    packages = with pkgs; [
      zigpkgs."0.16.0"
      pkg-config
      libGL
      libglvnd
      wayland
      wayland-protocols
      wayland-scanner
      libxkbcommon
      harfbuzz
      dejavu_fonts
    ];

    GOOP_DEMO_FONT_PATH = "${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSans.ttf";

    LD_LIBRARY_PATH = with pkgs;
      pkgs.lib.makeLibraryPath [
        libGL
        libglvnd
        wayland
        libxkbcommon
      ];
  }
