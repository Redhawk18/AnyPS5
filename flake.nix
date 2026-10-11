{
  description = "AnyPS5 — relinker package and development shells";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # Only the relinker is packaged. It builds from the tracked sources
          # alone, so it needs neither the 3rdparty submodules nor the FFmpeg
          # download CMake performs at configure time, neither of which a
          # sandboxed build can reach. The full build stays a devShell concern.
          mkRelinker =
            {
              stdenv ? pkgs.stdenv,
              cmake ? pkgs.cmake,
              ninja ? pkgs.ninja,
              git ? pkgs.git,
              python3 ? pkgs.python3,
              glibcStatic ? pkgs.glibc.static,
              cmakeBuildType ? "Release",
              runTests ? true,
              excludedTests ? defaultExcludedTests,
              extraCmakeFlags ? [ ],
            }:
            stdenv.mkDerivation {
              pname = "anyps5-relinker";
              version = "0-unstable-2026-10-11";

              src = self;

              nativeBuildInputs = [
                cmake
                ninja
              ]
              ++ pkgs.lib.optional (python3 != null) python3
              ++ pkgs.lib.optional (runTests && git != null) git;

              cmakeBuildType = cmakeBuildType;

              cmakeFlags = [
                (pkgs.lib.cmakeBool "ANYPS5_RELINKER_ONLY" true)
                (pkgs.lib.cmakeBool "BUILD_TESTING" runTests)
              ]
              ++ extraCmakeFlags;

              # libc.a and libm.a for the project's -static link. This must stay a
              # bare LIBRARY_PATH: putting glibc.static in buildInputs injects its
              # -L ahead of the default glibc through NIX_LDFLAGS, and the shared
              # guest_module_args_host.prx then links libc.a and fails with
              # "local-exec is incompatible with -shared".
              env.LIBRARY_PATH = "${glibcStatic}/lib";

              doCheck = runTests;
              checkPhase = ''
                runHook preCheck
                ctest --output-on-failure --parallel $NIX_BUILD_CORES ${
                  pkgs.lib.optionalString (
                    excludedTests != [ ]
                  ) ''-E "${pkgs.lib.concatStringsSep "|" excludedTests}"''
                }
                runHook postCheck
              '';

              installPhase = ''
                runHook preInstall
                install -Dm755 core/relinker/relinker "$out/bin/anyps5-relinker"
                runHook postInstall
              '';

              passthru = {
                inherit excludedTests;
              };

              meta = {
                description = "AnyPS5 relinker: converts PS5 executables to native Linux ELF or Windows PE";
                homepage = "https://github.com/boykopovar/AnyPS5";
                license = pkgs.lib.licenses.gpl2Only;
                mainProgram = "anyps5-relinker";
                platforms = systems;
              };
            };

          # These four cannot pass in a sandboxed pure build, so they are skipped
          # by default rather than left to fail. Override `excludedTests` to run
          # them anyway, or build the devShell where all 105 pass.
          #
          #   import_audit                 asserts a 40-hex source_commit, but a
          #                                flake source tree carries no .git
          #   linux_entry_argv             these three execute the relinked output
          #   linux_program_header_order   ELF, which the build sandbox refuses
          #   linux_input_program_headers
          defaultExcludedTests = [
            "^import_audit$"
            "^linux_entry_argv$"
            "^linux_program_header_order$"
            "^linux_input_program_headers$"
          ];
        in
        rec {
          default = relinker;
          relinker = pkgs.lib.makeOverridable mkRelinker { };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          toolchain = [
            pkgs.cmake
            pkgs.ninja
            pkgs.gcc
            pkgs.python3
            pkgs.ccache
            pkgs.pkg-config
          ];

          # The project links with -static -static-libgcc -static-libstdc++, so the
          # link stage needs libc.a and libm.a. Putting glibc.static on PATH is not
          # enough; the archives must be on the library search path.
          staticLibc = "${pkgs.glibc.static}/lib";

          # SDL2 is built from the 3rdparty submodule, but its X11 backend compiles
          # against the host X11 headers (libx11-dev / libxext-dev upstream).
          fullBuildDeps = [
            pkgs.libx11
            pkgs.libxext
            pkgs.libxcb
            pkgs."libxcb-util"
            pkgs."libxcb-keysyms"
            pkgs.libxrender
            pkgs.libxxf86vm
            pkgs.libxrandr
            pkgs.libxcursor
            pkgs.libxi
            pkgs.libxfixes
            pkgs.libxscrnsaver
            pkgs.wayland
            pkgs.wayland-protocols
            pkgs.libxkbcommon
            pkgs.libdrm
            pkgs.mesa
            pkgs.vulkan-loader
            pkgs.vulkan-headers
            pkgs.alsa-lib
            pkgs.libpulseaudio
            pkgs.cacert
          ];
        in
        {
          # Verified: 105/105 ctest pass. Needs no submodules, no GPU, no PS5 title.
          #
          #   cmake -S . -B build-relinker -G Ninja -DCMAKE_BUILD_TYPE=Release \
          #     -DANYPS5_RELINKER_ONLY=ON -DBUILD_TESTING=ON
          #   cmake --build build-relinker --parallel
          #   ctest --test-dir build-relinker --output-on-failure --parallel 8
          default = pkgs.mkShell {
            packages = toolchain;

            LIBRARY_PATH = staticLibc;

            shellHook = ''
              echo "AnyPS5 relinker-only shell — cmake $(cmake --version | head -1 | cut -d' ' -f3), $(g++ --version | head -1)"
              echo "configure: cmake -S . -B build-relinker -G Ninja -DCMAKE_BUILD_TYPE=Release -DANYPS5_RELINKER_ONLY=ON -DBUILD_TESTING=ON"
            '';
          };

          # Verified 2026-10-11: configures, builds, builds the `libs` target (120
          # .prx files), and runs the guest_* ctest suite green. Needs submodules
          # and the separate EXCLUDE_FROM_ALL `libs` target:
          #
          #   git submodule update --init --recursive
          #   cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON
          #   cmake --build build --parallel
          #   cmake --build build --target libs --parallel
          #
          # CMake downloads FFmpeg during configure unless FFMPEG_PREBUILT_DIR is
          # set; SSL_CERT_FILE below is what makes that download work.
          full = pkgs.mkShell {
            packages = toolchain ++ fullBuildDeps;

            LIBRARY_PATH = staticLibc;
            SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
            VULKAN_SDK = "${pkgs.vulkan-headers}";

            # The AGC tests dlopen libvulkan.so.1 at run time, which mkShell's
            # build-time paths do not cover; without this 273 agc_* tests fail
            # with "cannot load Vulkan".
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
              pkgs.vulkan-loader
              pkgs.mesa
            ];

            shellHook = ''
              export VK_ICD_FILENAMES="''${VK_ICD_FILENAMES:-${pkgs.mesa}/share/vulkan/icd.d/lvp_icd.x86_64.json}"
              echo "AnyPS5 full-build shell"
              echo "build: cmake --build build --parallel && cmake --build build --target libs --parallel"
            '';
          };
        }
      );
    };
}
