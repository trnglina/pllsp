{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    {
      self,
      nixpkgs,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      src = ./src;

      eachSystem = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      entryPoint = pkgs: {
        tpl = "${pkgs.trealla}/bin/tpl -q -f main.pl";
        scryer = "${pkgs.scryer-prolog}/bin/scryer-prolog -f main.pl";
      };
    in
    {
      packages = eachSystem (
        pkgs:
        nixpkgs.lib.mapAttrs' (
          name: load:
          nixpkgs.lib.nameValuePair "pllsp-${name}" (
            pkgs.writeShellScriptBin "pllsp-${name}" ''
              cd ${src}
              exec ${load} -g main
            ''
          )
        ) (entryPoint pkgs)
      );

      apps = eachSystem (
        pkgs:
        nixpkgs.lib.mapAttrs (name: pkg: {
          type = "app";
          program = "${pkg}/bin/${name}";
        }) self.packages.${pkgs.stdenv.hostPlatform.system}
      );

      devShells = eachSystem (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.trealla
            pkgs.scryer-prolog
          ];
        };
      });
    };
}
