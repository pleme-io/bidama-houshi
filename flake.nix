{
  description = "bidama-houshi, a blue distribution";

  inputs.blue.url = "github:pleme-io/blue";

  inputs.engenho = {
    url = "github:pleme-io/engenho";
    flake = false;
  };

  outputs = { blue, engenho, ... }:
    let
      p = blue.lib.project { src = ./.; };
      kindsFresh = system:
        let
          pkgs = blue.inputs.nixpkgs.legacyPackages.${system};
          generated = "${engenho}/engenho-types/blue/kinds.b";
          fresh = builtins.readFile generated == builtins.readFile ./bidamas/houshi/kurasuta/kinds/kinds.b;
        in
        pkgs.runCommand "kurasuta-kinds-fresh" { } (if fresh then "touch $out" else ''
          echo "bidamas/houshi/kurasuta/kinds/kinds.b is not engenho-kube-codegen's output at the pinned engenho: copy ${generated} over it" >&2
          exit 1
        '');
    in
    p // {
      checks = builtins.mapAttrs (system: cs: cs // { kurasuta-kinds-fresh = kindsFresh system; }) p.checks;
    };
}
