let
  npins = import ./npins;

  mkPackages =
    {
      lib,
      callPackage,
    }:
    if builtins.pathExists ./nix/packages then
      lib.packagesFromDirectoryRecursive {
        inherit callPackage;
        directory = ./nix/packages;
      }
    else
      { };

  # Package arguments are scoped against `final` so packages in nix/packages/
  # can reference each other. Directory discovery uses `prev.lib`, avoiding
  # forcing the overlay fixpoint merely to determine its attribute names.
  overlay =
    final: prev:
    mkPackages {
      inherit (prev) lib;
      inherit (final) callPackage;
    };
in
{
  sources ? npins,
  nixpkgs ? sources.nixpkgs,
  pkgs ? import nixpkgs { },
  # snail is consumed as a Zig *source* via `zig build --system`; default to
  # goop's own pin, superprojects override to a sibling checkout.
  snail-src ? npins.snail,
  ...
}:
let
  # Surface snail-src by name so goop.nix's `snail-src` callPackage arg
  # resolves it (the shoal pattern).
  finalPkgs = (pkgs.extend (_: _: { inherit snail-src; })).extend overlay;
in
rec {
  packages = mkPackages {
    inherit (pkgs) lib;
    inherit (finalPkgs) callPackage;
  };
  inherit overlay;
  shell = finalPkgs.callPackage ./nix/shell.nix { };

  default = packages.goop;

  # Compatibility aliases retained from the previous top-level interface.
  goop = packages.goop;
  lib = packages.goop;
  demo = packages.goop;
}
