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
  nixpkgs ? npins.nixpkgs,
  pkgs ? import nixpkgs { },
}:
let
  finalPkgs = pkgs.extend overlay;
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
