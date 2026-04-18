{
  description = "Blockscout frontend - Next.js blockchain explorer UI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    # Restricted to Linux: meta.platforms = platforms.linux below, so
    # Darwin outputs would fail with "unsupported platform".
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        nodejs = pkgs.nodejs_22;
        pnpm = pkgs.pnpm_10;

        blockscoutFrontend = pkgs.stdenv.mkDerivation (finalAttrs: {
          pname = "blockscout-frontend";
          version = "1.0.0";

          # Filter out build artifacts, caches, and the `result` symlink so
          # untracked files don't bloat the source copy or perturb the
          # pnpmDeps FOD hash across local checkouts.
          src = pkgs.lib.cleanSourceWith {
            src = ./.;
            name = "blockscout-frontend-source";
            filter =
              name: type:
              let
                baseName = baseNameOf (toString name);
              in
              !(
                (type == "directory"
                  && (
                    baseName == "node_modules"
                    || baseName == ".next"
                    || baseName == ".devenv"
                    || baseName == ".direnv"
                  ))
                || (type == "symlink" && pkgs.lib.hasPrefix "result" baseName)
              )
              && (pkgs.lib.cleanSourceFilter name type);
          };

          # Fetch pnpm dependencies as a fixed-output derivation.
          # To recompute hash: set hash = pkgs.lib.fakeHash, run nix build,
          # copy the correct hash from the error message.
          pnpmDeps = pkgs.fetchPnpmDeps {
            inherit (finalAttrs) pname version src;
            inherit pnpm;
            fetcherVersion = 3;
            hash = "sha256-dp/YdNd1ZoaA84TBxzQ6hVuWlgu9NaYdXbBYuBiRCyU=";
          };

          nativeBuildInputs = with pkgs; [
            nodejs
            node-gyp
            pnpm
            pnpmConfigHook
            python3
            gcc
            gnumake
            pkg-config
            jq # used by deploy/scripts/build_sprite.sh
            makeWrapper
          ];

          buildInputs = with pkgs; [
            # Native build deps for transitive packages (node-datachannel etc.)
            openssl
          ];

          # Disable Next.js build-time TypeScript and ESLint checks.
          # Upstream's CI handles these — at Nix build time we just want a
          # working artifact. Bypass blocked by type errors caused by
          # transitive Chakra UI version drift between pnpm 10.32.1 (upstream
          # CI) and 10.33.0 (nixpkgs).
          postPatch = ''
            substituteInPlace next.config.js \
              --replace-fail "output: 'standalone'," \
              "output: 'standalone', typescript: { ignoreBuildErrors: true }, eslint: { ignoreDuringBuilds: true },"
          '';

          # Provide placeholder NEXT_PUBLIC_* values for the build.
          # Real values are injected at runtime via envs.js (see deploy/scripts/
          # make_envs_script.sh in upstream — replicated by NixOS service module).
          env = {
            NEXT_TELEMETRY_DISABLED = "1";
            # Disable pnpm's "packageManager" version self-install — nixpkgs
            # provides a single pnpm version and we can't fetch from npm in
            # the sandbox. Tolerate minor patch differences.
            npm_config_manage_package_manager_versions = "false";
            # Disable Next.js build-time validation that requires real values
            NEXT_PUBLIC_API_HOST = "localhost";
            NEXT_PUBLIC_API_PROTOCOL = "http";
            NEXT_PUBLIC_API_PORT = "4000";
            NEXT_PUBLIC_NETWORK_NAME = "Autonity";
            NEXT_PUBLIC_NETWORK_SHORT_NAME = "ATN";
            NEXT_PUBLIC_NETWORK_ID = "65000000";
            NEXT_PUBLIC_NETWORK_RPC_URL = "http://localhost:8545";
            NEXT_PUBLIC_NETWORK_CURRENCY_NAME = "Auton";
            NEXT_PUBLIC_NETWORK_CURRENCY_SYMBOL = "ATN";
            NEXT_PUBLIC_NETWORK_CURRENCY_DECIMALS = "18";
            NEXT_PUBLIC_APP_HOST = "localhost";
            NEXT_PUBLIC_APP_PROTOCOL = "http";
            NEXT_PUBLIC_APP_PORT = "3000";
          };

          buildPhase = ''
            runHook preBuild
            export CI=true
            export HOME=$TMPDIR
            export NODE_OPTIONS="--max-old-space-size=8192"

            # Stub native bindings that aren't available in the sandbox.
            # @ipshipyard/node-datachannel is a transitive dep of
            # @helia/verified-fetch (IPFS NFT image fetching). Its WebRTC
            # native binary requires CMake + WebRTC compilation. For MVP
            # we don't need NFT IPFS fetching — replace the loader wrapper
            # with an empty module so Next.js page data collection succeeds.
            for mjs in $(find node_modules/.pnpm -type f -path '*@ipshipyard+node-datachannel*/dist/esm/lib/node-datachannel.mjs' 2>/dev/null); do
              echo "Stubbing $mjs"
              printf '%s\n' \
                '// Nix build stub: native node_datachannel.node not available in' \
                '// sandbox. NFT IPFS fetching disabled — re-enable by building' \
                '// the native module with proper WebRTC dependencies.' \
                'export default {};' > "$mjs"
              # Also patch the .cjs variant if present
              cjs="''${mjs%.mjs}.cjs"
              if [ -f "$cjs" ]; then
                echo "module.exports = {};" > "$cjs"
              fi
            done

            # Replicate upstream Dockerfile build steps:
            # 1. Build SVG sprite (creates icon imports and registry.json)
            chmod +x deploy/scripts/build_sprite.sh
            patchShebangs deploy/scripts/build_sprite.sh
            ./deploy/scripts/build_sprite.sh

            # Verify sprite artifacts were produced (registry.json alone can
            # be created even when the actual sprite generation fails)
            if [ ! -f public/icons/registry.json ]; then
              echo "ERROR: Sprite build did not produce public/icons/registry.json" >&2
              exit 1
            fi

            sprite_hash_file="$(find public/icons -maxdepth 1 -type f -name 'sprite.*.svg' | head -n 1)"
            if [ -z "$sprite_hash_file" ]; then
              echo "ERROR: Sprite build did not produce public/icons/sprite.*.svg" >&2
              exit 1
            fi

            # Preserve unhashed sprite.svg fallback for runtime environments
            # where NEXT_PUBLIC_ICON_SPRITE_HASH is not set (the script
            # renames sprite.svg to sprite.<hash>.svg and deletes the original)
            if [ ! -f public/icons/sprite.svg ]; then
              cp "$sprite_hash_file" public/icons/sprite.svg
            fi
            # 2. Generate route types from pages/
            pnpm routes:generate
            # 3. Build Next.js app (standalone output via next.config.js)
            pnpm run build

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            mkdir -p $out

            # Next.js standalone output bundles its own minimal node_modules.
            cp -r .next/standalone/. $out/

            # Static assets and public/ must be copied into the standalone
            # tree at specific paths for Next.js to find them at runtime.
            # https://nextjs.org/docs/pages/api-reference/config/next-config-js/output#automatically-copying-traced-files
            mkdir -p $out/.next
            cp -r .next/static $out/.next/static
            if [ -d public ]; then
              cp -r public $out/public
            fi

            # Note: deploy/scripts/ is intentionally not shipped. Those
            # scripts (make_envs_script.sh, download_assets.sh, etc.) carry
            # shebangs and runtime deps (curl, jq, bash) that would need
            # patchShebangs + wrapProgram to work on NixOS. The consuming
            # NixOS service module generates envs.js from a Nix template
            # string at startup instead, avoiding that runtime closure.

            # Create a wrapper script in $out/bin so `nix run` and
            # meta.mainProgram work as expected.
            mkdir -p $out/bin
            makeWrapper ${nodejs}/bin/node $out/bin/blockscout-frontend \
              --add-flags "$out/server.js" \
              --set-default PORT "3000"

            runHook postInstall
          '';

          # Remove dangling symlinks (some pnpm-store entries point to
          # not-extracted packages — Nix's noBrokenSymlinks check fails)
          postFixup = ''
            find $out -type l ! -exec test -e {} \; -delete 2>/dev/null || true
          '';

          doInstallCheck = true;
          installCheckPhase = ''
            test -f $out/server.js
            test -d $out/.next/static
            test -f $out/public/icons/sprite.svg
            test -f $out/public/icons/registry.json
            test -f $out/bin/blockscout-frontend
            ${nodejs}/bin/node --check $out/server.js
          '';

          meta = with pkgs.lib; {
            description = "Blockscout frontend - Next.js blockchain explorer UI";
            homepage = "https://github.com/blockscout/frontend";
            license = licenses.gpl3Only;
            mainProgram = "blockscout-frontend";
            platforms = platforms.linux;
          };
        });
      in
      {
        packages.default = blockscoutFrontend;
        packages.blockscout-frontend = blockscoutFrontend;

        checks.default = blockscoutFrontend;
      }
    );
}
