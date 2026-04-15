{ pkgs, ... }:

{
  languages.javascript = {
    enable = true;
    package = pkgs.nodejs_22;
    pnpm = {
      enable = true;
      package = pkgs.pnpm_10;
      install.enable = false;
    };
  };

  packages = with pkgs; [
    git
    gnumake
    python3
  ];

  enterShell = ''
    echo "Blockscout frontend development environment"
    echo "Node version: $(node --version)"
    echo "pnpm version: $(pnpm --version)"
  '';
}
