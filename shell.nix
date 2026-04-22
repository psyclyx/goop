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
      fontconfig
      libGL
      libglvnd
      wayland
      wayland-protocols
      wayland-scanner
      libxkbcommon
      harfbuzz
      noto-fonts
      dejavu_fonts
    ];

    FONTCONFIG_FILE = pkgs.makeFontsConf {
      fontDirectories = with pkgs; [
        noto-fonts
        dejavu_fonts
      ];
    };

    LD_LIBRARY_PATH = with pkgs;
      pkgs.lib.makeLibraryPath [
        libGL
        libglvnd
        wayland
        libxkbcommon
      ];
  }
