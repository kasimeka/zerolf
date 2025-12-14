{
  nixConfig.bash-prompt-prefix = ''(zig) '';
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    systems.url = "github:nix-systems/default";

    zig.url = "github:mitchellh/zig-overlay";
    zls.url = "github:zigtools/zls";
  };

  outputs = inputs: let
    forAllSystems = f:
      inputs.nixpkgs.lib.genAttrs
      (import inputs.systems)
      (system: f inputs.nixpkgs.legacyPackages.${system});
  in {
    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
        packages = [
          inputs.zig.packages.${pkgs.stdenv.hostPlatform.system}.master
          inputs.zls.packages.${pkgs.stdenv.hostPlatform.system}.default
        ];
        shellHook = ''echo made with love by wrd'';
      };
    });
  };
}
