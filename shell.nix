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
      mesa
      wayland
      wayland-protocols
      wayland-scanner
      libxkbcommon
      harfbuzz
      noto-fonts
      dejavu_fonts
      imagemagick
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

    # When GOOP_FORCE_SOFTWARE_GL is set in the calling environment
    # (e.g. by CI on a headless runner), point libglvnd at the
    # nix-provided mesa EGL ICD and force the llvmpipe rasterizer.
    # Local developers with hardware GL are unaffected.
    shellHook = ''
      if [ -n "$GOOP_FORCE_SOFTWARE_GL" ]; then
        export __EGL_VENDOR_LIBRARY_FILENAMES=${pkgs.mesa}/share/glvnd/egl_vendor.d/50_mesa.json
        export LIBGL_ALWAYS_SOFTWARE=1
        export GALLIUM_DRIVER=llvmpipe
      fi
    '';
  }
