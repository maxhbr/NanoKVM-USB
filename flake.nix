{
  description = "NanoKVM-USB – KVM over USB desktop application";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;

        nodejs = pkgs.nodejs_22;
        # pnpm 10 still reads/writes the lockfileVersion 9.0 used by the project
        pnpm = pkgs.pnpm;

        # ---------------------------------------------------------------------------
        # Step 1 – Fixed-output derivation: fetch all pnpm dependencies.
        #
        # This derivation has network access (because it declares outputHash).
        # It runs `pnpm install --frozen-lockfile`, which:
        #   • Downloads all npm packages.
        #   • Runs the `electron` post-install script (allowed via onlyBuiltDependencies)
        #     which downloads the platform-specific Electron binary into
        #     node_modules/electron/dist/.
        #   • Does NOT run serialport's install script; its prebuilt .node files are
        #     shipped inside the npm package itself and selected at runtime.
        #
        # To obtain the correct hash on first use:
        #   1. Set outputHash to lib.fakeHash (or the placeholder below).
        #   2. Run: nix build .#desktop 2>&1 | grep "got:"
        #   3. Replace the placeholder with the hash printed in the error.
        # ---------------------------------------------------------------------------
        pnpmDeps = pkgs.stdenv.mkDerivation {
          name = "nanokvm-usb-pnpm-deps";

          # Only feed package.json, pnpm-lock.yaml, and .npmrc to the FOD so that
          # changes to source files do not invalidate the dependency cache.
          src = lib.cleanSourceWith {
            src = ./desktop;
            filter = name: _type:
              builtins.elem (baseNameOf name) [
                "package.json"
                "pnpm-lock.yaml"
                ".npmrc"
              ];
          };

          nativeBuildInputs = [ pnpm nodejs pkgs.cacert ];

          buildPhase = ''
            export HOME="$TMPDIR"
            export PNPM_HOME="$TMPDIR/pnpm-home"
            export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            export NODE_EXTRA_CA_CERTS="$SSL_CERT_FILE"
            mkdir -p "$PNPM_HOME"
            pnpm install --frozen-lockfile
            cp -r node_modules "$out"
          '';

          # Nothing extra to install; buildPhase writes directly to $out.
          installPhase = "true";

          # Disable fixup so that patchShebangs does not embed Nix store paths inside
          # the FOD output (fixed-output derivations may not reference store paths).
          dontFixup = true;

          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
          # Replace this placeholder with the real hash after the first failed build.
          outputHash = "sha256-+a7SkvluhEShPAeZWJn7g+jxW7dsHCpUHJwG2lw3ldA=";
        };

        # ---------------------------------------------------------------------------
        # Step 2 – Build the TypeScript / React source with electron-vite.
        #
        # Produces:
        #   out/main/index.js      – main process bundle
        #   out/preload/index.js   – preload script bundle
        #   out/renderer/          – renderer HTML + assets
        #
        # A symlink node_modules -> pnpmDeps is installed alongside the output so
        # that runtime require() calls (e.g. for serialport) resolve correctly.
        # ---------------------------------------------------------------------------
        builtApp = pkgs.stdenv.mkDerivation {
          pname = "nanokvm-usb-app";
          version = "1.1.4";
          src = ./desktop;

          nativeBuildInputs = [ nodejs ];

          buildPhase = ''
            export HOME="$TMPDIR"
            # Copy pre-fetched modules and make them writable for build-tool caches.
            cp -r "${pnpmDeps}" node_modules
            chmod -R u+w node_modules
            node_modules/.bin/electron-vite build
          '';

          installPhase = ''
            mkdir -p "$out"
            cp -r out          "$out/out"
            cp    package.json "$out/package.json"
            # electron-updater looks for this file next to the main bundle.
            cp    dev-app-update.yml "$out/out/main/dev-app-update.yml"
            # Symlink to the store path so native modules resolve at runtime.
            ln -s "${pnpmDeps}" "$out/node_modules"
          '';
        };

        # ---------------------------------------------------------------------------
        # Step 3 – Wrap in an FHS environment.
        #
        # The Electron binary bundled by pnpm is a standard Linux ELF that expects
        # system libraries at conventional FHS paths (/lib, /usr/lib, …).
        # buildFHSEnv satisfies those expectations via bubblewrap without altering
        # the binary itself.
        # ---------------------------------------------------------------------------
        launchScript = pkgs.writeShellScript "nanokvm-usb-launch" ''
          exec "${builtApp}/node_modules/electron/dist/electron" \
               "${builtApp}/out/main/index.js" "$@"
        '';

        desktop = pkgs.buildFHSEnv {
          name = "nanokvm-usb";

          targetPkgs = p: with p; [
            # Graphics / UI
            alsa-lib
            at-spi2-atk
            at-spi2-core
            atk
            cairo
            cups
            dbus
            expat
            fontconfig
            freetype
            gdk-pixbuf
            glib
            gtk3
            libdrm
            libGL
            libuuid
            libxkbcommon
            libgbm
            mesa
            nspr
            nss
            pango
            # Serial-port / udev
            systemd
            # X11
            libx11
            libxscrnsaver
            libxcomposite
            libxcursor
            libxdamage
            libxext
            libxfixes
            libxi
            libxrandr
            libxrender
            libxtst
            libxcb
          ];

          runScript = launchScript;

          meta = {
            description = "NanoKVM-USB desktop application – KVM over USB";
            homepage    = "https://github.com/sipeed/NanoKVM-USB";
            license     = lib.licenses.mit;
            platforms   = lib.platforms.linux;
            mainProgram = "nanokvm-usb";
          };
        };

      in {
        # ── Packages ──────────────────────────────────────────────────────────────
        packages = {
          desktop = desktop;
          default = desktop;
        };

        # ── Apps (nix run .#desktop  /  nix run) ──────────────────────────────
        apps = {
          desktop = {
            type    = "app";
            program = "${desktop}/bin/nanokvm-usb";
          };
          default = {
            type    = "app";
            program = "${desktop}/bin/nanokvm-usb";
          };
        };

        # ── Dev shell (nix develop) ────────────────────────────────────────────
        # Provides Node.js + pnpm so you can run:
        #   cd desktop && pnpm install && pnpm dev
        devShells.default = pkgs.mkShell {
          buildInputs = [ nodejs pnpm ];
          shellHook = ''
            echo "NanoKVM-USB dev environment — Node $(node --version), pnpm $(pnpm --version)"
            echo "  cd desktop && pnpm install && pnpm dev"
          '';
        };
      }
    );
}
