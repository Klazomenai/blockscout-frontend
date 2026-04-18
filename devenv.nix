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
    jq # used by deploy/scripts/build_sprite.sh
    curl # used by deploy/scripts/download_assets.sh (dev flow)
  ];

  enterShell = ''
    echo "Blockscout frontend development environment"
    echo "Node version: $(node --version)"
    echo "pnpm version: $(pnpm --version)"
  '';
}
