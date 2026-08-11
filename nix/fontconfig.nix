{
  runCommand,
  fontconfig,
  dejavu_fonts,
  noto-fonts,
  noto-fonts-cjk-sans,
  noto-fonts-color-emoji,
}:
let
  notoFonts = noto-fonts;
  notoCjkFonts = noto-fonts-cjk-sans;
in
runCommand "goop-fontconfig-${fontconfig.version}" { } ''
  mkdir -p "$out/conf.d"
  for source in ${fontconfig.out}/etc/fonts/conf.d/*.conf; do
    name="$(basename "$source")"
    case "$name" in
      50-user.conf|51-local.conf) continue ;;
    esac
    ln -s "$source" "$out/conf.d/$name"
  done

  cat > "$out/fonts.conf" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <description>Goop's pinned Fontconfig ${fontconfig.version} environment</description>
  <include ignore_missing="no">$out/conf.d</include>
  <dir>${dejavu_fonts}/share/fonts/truetype</dir>
  <dir>${notoFonts}/share/fonts/noto</dir>
  <dir>${notoCjkFonts}/share/fonts/opentype/noto-cjk</dir>
  <dir>${noto-fonts-color-emoji}/share/fonts/noto</dir>
  <cachedir prefix="xdg">fontconfig/goop</cachedir>
</fontconfig>
EOF
''
