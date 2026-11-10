# The look shared by every machine and the installer: one accent colour and
# the NixOS snowflake recoloured with it (boot splash, wallpaper, fastfetch).
# Change `accent` (and the shades derived from it below) to restyle everything.
{ runCommand, nixos-icons, librsvg, imagemagick }:

let
  snowflake = "${nixos-icons}/share/icons/hicolor/scalable/apps/nix-snowflake.svg";
  png = name: size: runCommand name { nativeBuildInputs = [ librsvg ]; } ''
    rsvg-convert --width ${toString size} --height ${toString size} ${logoSvg} -o $out
  '';
  # The snowflake's blues (dark -> light), replaced by teals of the same weight
  logoSvg = runCommand "nixos-snowflake-teal.svg" { } ''
    sed -e 's/#415e9a/#12806a/Ig' -e 's/#4a6baf/#159b80/Ig' \
        -e 's/#5277c3/#1abc9c/Ig' -e 's/#699ad7/#3fcdb0/Ig' \
        -e 's/#7eb1dd/#5fdcc3/Ig' -e 's/#7ebae4/#76e4cd/Ig' \
        ${snowflake} > $out
    ! grep -qi '#5277c3\|#7ebae4' $out
  '';
in
{
  accent = "#1abc9c";
  accentRgb = "26,188,156";     # the same, as Plasma's kdeglobals wants it
  accentLight = "#5fdcc3";
  background = "#141618";       # Breeze Dark's window background, darkened

  inherit logoSvg;
  logo = png "nixos-snowflake-teal.png" 160; # boot splash
  icon = png "nixos-snowflake-teal-64.png" 64;

  # 4K, scaled down by Plasma: dark radial gradient, snowflake in the middle
  wallpaper = runCommand "wallpaper-teal.png" { nativeBuildInputs = [ imagemagick ]; } ''
    magick -size 3840x2160 radial-gradient:'#20302e'-'#101213' \
      ${png "snowflake-900.png" 900} -gravity center -composite \
      -depth 8 $out
  '';
}
