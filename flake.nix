{
  description = "Jujutsu VCS, a Git-compatible DVCS that is both simple and powerful";

  inputs = {
    # For listing and iterating nix systems
    flake-utils.url = "github:numtide/flake-utils";

    # For installing non-standard rustc versions
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
    rust-overlay.inputs.flake-utils.follows = "flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay }: {
    overlays.default = (final: prev: {
      jujutsu = self.packages.${final.system}.jujutsu;
    });
  } //
  (flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          rust-overlay.overlays.default
        ];
      };

      filterSrc = src: regexes:
        pkgs.lib.cleanSourceWith {
          inherit src;
          filter = path: type:
            let
              relPath = pkgs.lib.removePrefix (toString src + "/") (toString path);
            in
            pkgs.lib.all (re: builtins.match re relPath == null) regexes;
        };

      ourRustVersion = pkgs.rust-bin.selectLatestNightlyWith (toolchain: toolchain.complete);

      ourRustPlatform = pkgs.makeRustPlatform {
        rustc = ourRustVersion;
        cargo = ourRustVersion;
      };

      # these are needed in both devShell and buildInputs
      darwinDeps = with pkgs; lib.optionals stdenv.isDarwin [
        darwin.apple_sdk.frameworks.Security
        darwin.apple_sdk.frameworks.SystemConfiguration
        libiconv
      ];

      # work around https://github.com/nextest-rs/nextest/issues/267
      # this needs to exist in both the devShell and preCheck phase!
      darwinNextestHack = pkgs.lib.optionalString pkgs.stdenv.isDarwin ''
        export DYLD_FALLBACK_LIBRARY_PATH=$(${ourRustVersion}/bin/rustc --print sysroot)/lib
      '';
      
      # NOTE (aseipp): on Linux, go ahead and use mold by default to improve
      # link times a bit; mostly useful for debug build speed, but will help
      # over time if we ever get more dependencies, too
      useMoldLinker = pkgs.stdenv.isLinux;

      # these are needed in both devShell and buildInputs
      linuxNativeDeps = with pkgs; lib.optionals stdenv.isLinux [
        mold-wrapped
      ];

    in
    {
      packages = {
        jujutsu = ourRustPlatform.buildRustPackage {
          pname = "jujutsu";
          version = "unstable-${self.shortRev or "dirty"}";

          buildFeatures = [ "packaging" ];
          cargoBuildFlags = [ "--bin" "jj" ]; # don't build and install the fake editors
          useNextest = true;
          src = filterSrc ./. [
            ".*\\.nix$"
            "^.jj/"
            "^flake\\.lock$"
            "^target/"
          ];

          cargoLock.lockFile = ./Cargo.lock;
          nativeBuildInputs = with pkgs; [
            gzip
            installShellFiles
            makeWrapper
            pkg-config

            # for signing tests
            gnupg 
            openssh
          ] ++ linuxNativeDeps;
          buildInputs = with pkgs; [
            openssl zstd libgit2 libssh2
          ] ++ darwinDeps;

          ZSTD_SYS_USE_PKG_CONFIG = "1";
          LIBSSH2_SYS_USE_PKG_CONFIG = "1";
          RUSTFLAGS = pkgs.lib.optionalString useMoldLinker "-C link-arg=-fuse-ld=mold";
          NIX_JJ_GIT_HASH = self.rev or "";
          CARGO_INCREMENTAL = "0";

          preCheck = ''
            export RUST_BACKTRACE=1
          '' + darwinNextestHack;

          postInstall = ''
            $out/bin/jj util mangen > ./jj.1
            installManPage ./jj.1

            installShellCompletion --cmd jj \
              --bash <($out/bin/jj util completion bash) \
              --fish <($out/bin/jj util completion fish) \
              --zsh <($out/bin/jj util completion zsh)
          '';
        };
        default = self.packages.${system}.jujutsu;
      };

      apps.default = {
        type = "app";
        program = "${self.packages.${system}.jujutsu}/bin/jj";
      };

      formatter = pkgs.nixpkgs-fmt;

      checks.jujutsu = self.packages.${system}.jujutsu.overrideAttrs ({ ... }: {
        # FIXME (aseipp): when running `nix flake check`, this will override the
        # main package, and nerf the build and installation phases. this is
        # because for some inexplicable reason, the cargo cache gets invalidated
        # in between buildPhase and checkPhase, causing every nix CI build to be
        # 2x as long.
        #
        # upstream issue: https://github.com/NixOS/nixpkgs/issues/291222
        buildPhase = "true";
        installPhase = "touch $out";
        # NOTE (aseipp): buildRustPackage also, by default, runs `cargo check`
        # in `--release` mode, which is far slower; the existing CI builds all
        # use the default `test` profile, so we should too.
        cargoCheckType = "test";
      });

      devShells.default = pkgs.mkShell {
        buildInputs = with pkgs; [
          ourRustVersion

          # Foreign dependencies
          openssl zstd libgit2 libssh2
          pkg-config

          # Make sure rust-analyzer is present
          rust-analyzer

          # Additional tools recommended by contributing.md
          cargo-deny
          cargo-insta
          cargo-nextest
          cargo-watch

          # In case you need to run `cargo run --bin gen-protos`
          protobuf

          # To run the signing tests
          gnupg
          openssh

          # For building the documentation website
          poetry
        ] ++ darwinDeps ++ linuxNativeDeps;

        shellHook = ''
          export RUST_BACKTRACE=1
          export ZSTD_SYS_USE_PKG_CONFIG=1
          export LIBSSH2_SYS_USE_PKG_CONFIG=1
        '' + pkgs.lib.optionalString useMoldLinker ''
          export RUSTFLAGS="-C link-arg=-fuse-ld=mold"
        '' + darwinNextestHack;
      };
    }));
}
