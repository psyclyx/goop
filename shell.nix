let
  sources = import ./npins;
  pkgs = import sources.nixpkgs-unstable {};
in
  pkgs.mkShell {
    packages = with pkgs; [
      zig_0_16
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
