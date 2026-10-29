{
  description = "argocd-app-loader — repo toolchain (Helm 4 + helm-unittest, Task, pre-commit)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in
    {
      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = with pkgs; [
          (wrapHelm kubernetes-helm {
            plugins = [ kubernetes-helmPlugins.helm-unittest ];
          })
          go-task
          pre-commit
          nodejs # the markdownlint hook uses it instead of downloading a non-NixOS build
        ];
      };
    };
}
