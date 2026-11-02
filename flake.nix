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
        let
          mkLauncher =
            load:
            pkgs.writeShellScriptBin "pllsp" ''
              cd ${src}
              exec ${load} -g main
            '';
          launchers = nixpkgs.lib.mapAttrs' (
            name: load: nixpkgs.lib.nameValuePair "pllsp-${name}" (mkLauncher load)
          ) (entryPoint pkgs);
        in
        launchers
        // {
          default = launchers.pllsp-scryer;
        }
      );

      apps = eachSystem (
        pkgs:
        let
          packages = self.packages.${pkgs.stdenv.hostPlatform.system};
        in
        nixpkgs.lib.mapAttrs (_: pkg: {
          type = "app";
          program = "${pkg}/bin/pllsp";
        }) packages
      );

      devShells = eachSystem (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.trealla
            pkgs.scryer-prolog
            pkgs.python3
          ];
        };
      });
    };
}
