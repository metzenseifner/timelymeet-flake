{
  description = "Nix flake for TimelyMeet macOS calendar reminder app";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    timelymeet-src = {
      url = "github:Romancha/timelymeet/1.6.1";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      timelymeet-src,
    }:
    let
      inherit (nixpkgs) lib;

      supportedSystems = [
        "aarch64-darwin"
      ];
      forAllSystems = lib.genAttrs supportedSystems;

      # `hostToolchain` names the Apple toolchain that lives OUTSIDE the Nix
      # store. TimelyMeet is a SwiftUI .xcodeproj, and nixpkgs' `xcbuild` is a
      # 2019-vintage reimplementation that cannot compile modern Swift, so the
      # real Xcode is the only builder available.
      #
      # Plain English: this derivation is deliberately impure. It requires a
      # full Xcode install and `sandbox = false` in nix.conf. Two consequences
      # follow, both accepted on purpose:
      #   * the output is not substitutable, hence allowSubstitutes = false;
      #   * the derivation hash does not observe the Xcode version, so an Xcode
      #     upgrade will NOT invalidate a cached result — use
      #     `nix build --rebuild` (or delete the store path) after upgrading.
      hostToolchain = {
        xcodeSelect = "/usr/bin/xcode-select";
        xcodebuild = "/usr/bin/xcodebuild";
        codesign = "/usr/bin/codesign";
        # xcodebuild shells out to a long tail of host helpers (touch, plutil,
        # lsregister, dsymutil...), so it needs the host PATH, not the stdenv's.
        searchPath = "/usr/bin:/bin:/usr/sbin:/sbin";
      };

      # The app bundle, built by Xcode and sealed with an ad-hoc signature.
      timelymeetApp =
        pkgs:
        pkgs.stdenv.mkDerivation {
          pname = "timelymeet";
          version = "1.6.1";

          src = timelymeet-src;

          # No SwiftPM dependencies and no Nix build inputs: every compiler,
          # SDK and framework comes from the host Xcode.
          dontConfigure = true;

          # The bundle is ad-hoc signed at the end of buildPhase. Stripping or
          # rewriting install names afterwards would break that seal, so the
          # generic fixupPhase is switched off entirely.
          dontFixup = true;

          preferLocalBuild = true;
          allowSubstitutes = false;

          buildPhase = ''
            runHook preBuild

            xcodeHome="$NIX_BUILD_TOP/xcode-home"
            derivedData="$NIX_BUILD_TOP/DerivedData"
            mkdir -p "$xcodeHome"

            # Every host tool has to run under `env -i`. The darwin stdenv
            # exports DEVELOPER_DIR and SDKROOT pointing at nixpkgs' apple-sdk
            # stub, and xcodebuild silently consumes SDKROOT,
            # MACOSX_DEPLOYMENT_TARGET, ARCHS and friends as build-setting
            # overrides.
            #
            # Plain English: with the inherited environment,
            # `xcode-select --print-path` answers with the Nix SDK (which
            # contains no xcodebuild at all) and xcodebuild would compile the
            # app against the wrong SDK. A cleared environment lets the host
            # Xcode and the project's own build settings win.
            developerDir=$(
              /usr/bin/env -i PATH="${hostToolchain.searchPath}" \
                ${hostToolchain.xcodeSelect} --print-path 2>/dev/null || true
            )
            if [ ! -x "$developerDir/usr/bin/xcodebuild" ]; then
              echo "error: building TimelyMeet requires a full Xcode installation." >&2
              echo "       'xcode-select --print-path' gave: ''${developerDir:-<nothing>}" >&2
              echo "       The Command Line Tools alone cannot build a SwiftUI .xcodeproj." >&2
              echo "       Install Xcode, then: sudo xcode-select --switch /Applications/Xcode.app" >&2
              exit 1
            fi

            hostTool() {
              /usr/bin/env -i \
                HOME="$xcodeHome" \
                TMPDIR="$NIX_BUILD_TOP" \
                PATH="${hostToolchain.searchPath}" \
                DEVELOPER_DIR="$developerDir" \
                "$@"
            }

            # SwiftUI's #Preview is a macro, and the Swift frontend runs macro
            # plugins under sandbox-exec. The _nixbld build users cannot call
            # sandbox_apply ("Operation not permitted"), which turns every
            # #Preview into a hard compile error, so that nested sandbox is
            # switched off. The Nix build is already the isolation boundary.
            hostTool ${hostToolchain.xcodebuild} \
              -project TimelyMeet.xcodeproj \
              -scheme TimelyMeet \
              -configuration Release \
              -derivedDataPath "$derivedData" \
              -destination 'platform=macOS' \
              CODE_SIGNING_ALLOWED=NO \
              CODE_SIGNING_REQUIRED=NO \
              CODE_SIGN_IDENTITY="" \
              CODE_SIGN_STYLE=Manual \
              DEVELOPMENT_TEAM="" \
              ENABLE_USER_SCRIPT_SANDBOXING=NO \
              OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' \
              build

            # Xcode's own signing is disabled above because the project asks for
            # an "Apple Development" identity and team KY6MPSHF75, which no Nix
            # builder has. That leaves only a linker-generated signature: the
            # bundle is unsealed and carries no entitlements, so the app-sandbox
            # and calendar entitlements would be silently dropped. Re-signing
            # ad-hoc restores both.
            hostTool ${hostToolchain.codesign} \
              --force \
              --sign - \
              --timestamp=none \
              --entitlements TimelyMeet/TimelyMeet.entitlements \
              "$derivedData/Build/Products/Release/TimelyMeet.app"

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            mkdir -p "$out/Applications"
            cp -R \
              "$derivedData/Build/Products/Release/TimelyMeet.app" \
              "$out/Applications/"

            runHook postInstall
          '';

          meta = {
            description = "macOS menu bar app for iCal/meeting notifications";
            homepage = "https://github.com/Romancha/timelymeet";
            license = lib.licenses.asl20;
            platforms = lib.platforms.darwin;
          };
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        rec {
          timelymeet = timelymeetApp pkgs;
          default = timelymeet;
        }
      );

      # A menu bar app has no CLI entry point, so `nix run` hands the bundle to
      # LaunchServices rather than exec'ing the Mach-O directly. Launching via
      # `open` is what lets the sandbox and TCC prompts work.
      apps = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          launch = pkgs.writeShellScript "timelymeet-open" ''
            exec /usr/bin/open -a "${self.packages.${system}.default}/Applications/TimelyMeet.app" "$@"
          '';
        in
        rec {
          timelymeet = {
            type = "app";
            program = "${launch}";
            meta = {
              description = "Launch TimelyMeet via LaunchServices";
            };
          };
          default = timelymeet;
        }
      );

      # Development shell for local iteration. It has to undo the same stdenv
      # pollution the build does: mkShell inherits DEVELOPER_DIR and SDKROOT
      # from nixpkgs' apple-sdk, which makes /usr/bin/xcodebuild report
      # "tool 'xcodebuild' not found". Repointing them at the host Xcode is
      # enough here, since an interactive shell wants the Nix tools on PATH too.
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              coreutils
            ];
            shellHook = ''
              export PATH="$PATH:${hostToolchain.searchPath}"
              unset SDKROOT
              export DEVELOPER_DIR=$(
                /usr/bin/env -i PATH="${hostToolchain.searchPath}" \
                  ${hostToolchain.xcodeSelect} --print-path 2>/dev/null || true
              )
              echo "Using: $(type -P xcodebuild) (DEVELOPER_DIR=$DEVELOPER_DIR)"
              ${hostToolchain.xcodebuild} -version
            '';
          };
        }
      );
    };
}
