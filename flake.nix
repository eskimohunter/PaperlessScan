{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }: 
  let
    system = "x86_64-linux"; # update to your system
    pkgs = import nixpkgs {
      inherit system;
      # This allows all unfree packages in this environment
      config.allowUnfree = true; 
    };
  in {
    devShells.${system}.default = pkgs.mkShell {
      buildInputs = with nixpkgs.legacyPackages.x86_64-linux; [
        # sane-backends
        epsonscan2
        # img2pdf
        shellcheck
      ];
    };
  };
}