{
  lib,
  config,
  stdenvNoCC,
  # Swapping the interpreter also swaps the package set the runtime is built
  # from: `freetoken.override { python3 = pkgs.python313; }`.
  python3,
  makeWrapper,
  symlinkJoin,
  addDriverRunpath,
  gcc,
  binutils,
  ninja,
  bash,
  cmake,
  gnumake,

  # Pull in flashinfer's fused kernels. Turning this off leaves the runtime on
  # its pure-Triton fallbacks (`--attention-backend triton`), which is a much
  # smaller build. flashinfer is marked broken without `cudaSupport`, so on a
  # CPU-only nixpkgs this defaults off and you get a CLI that builds but cannot
  # serve — set `nixpkgs.config.cudaSupport` (or use this flake's packages).
  withAccel ? config.cudaSupport,

  # Extra python packages to expose to the runtime, e.g. `ps: [ ps.pynvml ]`.
  extraPythonPackages ? (_ps: [ ]),
}:

let
  inherit (python3.pkgs) freetoken;

  pythonEnv = python3.withPackages (
    ps:
    [ ps.freetoken ]
    ++ lib.optionals withAccel ps.freetoken.optional-dependencies.accel
    ++ extraPythonPackages ps
  );

  # FreeToken JIT-compiles CUDA kernels on first use (both its own and
  # flashinfer's), so the toolkit has to be there at *run* time, not just at
  # build time.
  #
  # The compile is driven by ninja, not by a direct compiler call: tvm-ffi
  # writes a `build.ninja` into its cache directory and shells out to a bare
  # `ninja` (`tvm_ffi.cpp.extension.build_ninja`), whose rules then invoke
  # `c++`, `nvcc` and `ld` by name as well. So all four have to be on PATH, or
  # the very first kernel launch dies with a bare
  # `FileNotFoundError: ... 'ninja'` from deep inside CUDA graph capture.
  #
  # `sh` belongs on that PATH for a less obvious reason. nixpkgs patches ninja
  # to run every rule as `posix_spawnp("sh", "-c", ...)`, which searches PATH,
  # where upstream hardcodes `/bin/sh` -- something a NixOS unit does not have.
  # None of the entries above provide one, so ninja aborts before it even looks
  # at the rule, with `ninja: fatal: posix_spawn: No such file or directory`.
  cudaHome = freetoken.cudaRuntimeHome;

  # nvcc force-includes `cuda_runtime.h` into every translation unit, and finds
  # it through the `INCLUDES` line of its own `nvcc.profile`. On a stock CUDA
  # install that line is `-I$(TOP)/include` and resolves against CUDA_HOME, so
  # the header comes along for free; nixpkgs instead pins it to the `cuda_nvcc`
  # store path, which holds nvcc's own headers and *not* cudart's. At build time
  # cudart's `dev` output patches the gap via the setup hook's
  # `NIX_CFLAGS_COMPILE`, but a JIT compile at run time has no setup hooks, so
  # every kernel fails with `cuda_runtime.h: No such file or directory` from
  # `<command-line>`. Point nvcc back at the joined CUDA_HOME, which does carry
  # both. `--prefix`, not `--set`, so a caller's own flags survive.
  nvccIncludeFlag = "-I${cudaHome}/include";

  # Triton's JIT cache is the one runtime cache that defaults outside
  # `$XDG_CACHE_HOME`: it lands in `$HOME/.triton`. That is more than
  # untidiness, because Triton compiles its CUDA driver shim into that
  # directory and then `dlopen()`s it. A `$HOME` mounted `noexec` — an
  # impermanence tmpfs, for instance, where only the persisted subdirectories
  # are real filesystems — therefore dies at the first kernel launch with
  # `ImportError: .../cuda_utils.cpython-*.so: failed to map segment from
  # shared object`, which says nothing about the mount that caused it. Point it
  # at the cache directory instead, which such setups do persist and do mount
  # executable.
  #
  # A default, not an override: `TRITON_CACHE_DIR` from the environment still
  # wins, which is how the NixOS module puts it under its own `cacheDir`.
  tritonCacheDefault = ''
    if [ -z "''${TRITON_CACHE_DIR:-}" ]; then
      export TRITON_CACHE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/freetoken/triton"
    fi
  '';
in
stdenvNoCC.mkDerivation {
  pname = "freetoken";
  inherit (freetoken) version;

  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    makeWrapper ${pythonEnv}/bin/ft $out/bin/ft \
      --set-default CUDA_HOME ${cudaHome} \
      --prefix NVCC_PREPEND_FLAGS ' ' ${lib.escapeShellArg nvccIncludeFlag} \
      --run ${lib.escapeShellArg tritonCacheDefault} \
      --prefix PATH : ${
        lib.makeBinPath [
          cudaHome
          gcc
          binutils
          ninja
          bash
          cmake
          gnumake
        ]
      } \
      --suffix LD_LIBRARY_PATH : ${addDriverRunpath.driverLink}/lib

    runHook postInstall
  '';

  passthru = {
    inherit
      cudaHome
      pythonEnv
      withAccel
      ;
    unwrapped = freetoken;
    python = python3;
  };

  meta = freetoken.meta // {
    description = "${freetoken.meta.description} (wrapped with a CUDA toolchain for runtime JIT)";
    mainProgram = "ft";
  };
}
