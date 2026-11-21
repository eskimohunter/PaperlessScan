{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }: 
  let
    system = "x86_64-linux"; # update to your system
    pkgs = import nixpkgs {
      inherit system;
      # Epson's network helper needs the (EOL) OpenSSL 1.1 libcrypto.
      config = {
        allowUnfree = true;
        permittedInsecurePackages = [ "openssl-1.1.1w" ];
      };
    };
  in {
    devShells.${system}.default = pkgs.mkShell {
      buildInputs = [
        # Network scanning (es2netif) ships in the optional non-free plugin bundle.
        (pkgs.epsonscan2.override { withNonFreePlugins = true; })
        pkgs.openssl_1_1
        pkgs.avahi
        pkgs.qpdf
        pkgs.webhook
        pkgs.shellcheck
      ];
      # es2netif dlopen()s libcrypto.so.1.1 for the scanner's TLS link;
      # without this it connects but sends no TLS handshake ("Unable to send data").
      shellHook = ''
        export LD_LIBRARY_PATH="${pkgs.openssl_1_1.out}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      '';
    };
  };
}