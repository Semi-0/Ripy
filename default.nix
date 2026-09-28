# Pin the complete compiler and dependency set, including the GHCJS toolchain.
{ system ? builtins.currentSystem }:
let
  platform = import (builtins.fetchTarball {
    url = "https://github.com/reflex-frp/reflex-platform/archive/f231e2425ac92339b8491cdd970930d63d9ad1ad.tar.gz";
  }) { inherit system; };
in platform.project ({ ... }: {
  packages.ripy-frontend = ./frontend;
  shells.ghc = [ "ripy-frontend" ];
  shells.ghcjs = [ "ripy-frontend" ];
})
