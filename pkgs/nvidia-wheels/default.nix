# NVIDIA's own prebuilt NCCL and NVSHMEM, taken from the wheels they publish to
# PyPI instead of nixpkgs' from-source builds.
#
# Both are hard `buildInputs` of `torch-bin` (nixpkgs drops the wheel's
# `nvidia-nccl-cu13`/`nvidia-nvshmem-cu13` pip dependencies and substitutes its
# own packages), and neither is in any binary cache: cache.nixos.org carries no
# unfree CUDA at all. Building NCCL from source means compiling its device
# kernels for every CUDA capability in `cudaCapabilities` -- the better part of
# an hour, for collectives that FreeToken never calls, since it serves from a
# single GPU.
#
# These are the same binaries PyPI's torch links against, so this is closer to
# upstream's tested configuration than the source build is, not further from it.
{
  lib,
  stdenv,
  fetchurl,
  unzip,
  autoPatchelfHook,
  cudaPackages,
}:

let
  mkNvidiaWheel =
    {
      pname,
      version,
      url,
      hash,
      # directory inside the wheel holding lib/ and include/
      subdir,
      description,
      # Plugins these libraries dlopen for transports and bootstraps that a
      # single-GPU engine never selects. Pulling rdma-core and an MPI into the
      # closure to satisfy them would be worse than leaving them unresolved.
      ignoreMissingDeps ? [ ],
    }:
    stdenv.mkDerivation (finalAttrs: {
      inherit pname version;

      src = fetchurl { inherit url hash; };

      nativeBuildInputs = [
        autoPatchelfHook
        unzip
      ];

      buildInputs = [
        (lib.getLib cudaPackages.cuda_cudart)
        stdenv.cc.cc.lib
      ];

      # The driver itself is never in the closure; it is deployed at runtime in
      # /run/opengl-driver/lib.
      autoPatchelfIgnoreMissingDeps = [ "libcuda.so.1" ] ++ ignoreMissingDeps;

      unpackPhase = ''
        runHook preUnpack
        unzip -qq $src -d wheel
        runHook postUnpack
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p $out
        cp -r wheel/${subdir}/lib $out/lib
        cp -r wheel/${subdir}/include $out/include
        runHook postInstall
      '';

      meta = {
        inherit description;
        homepage = "https://pypi.org/project/${finalAttrs.pname}-cu13/";
        license = lib.licenses.unfreeRedistributable;
        sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
        platforms = [ "x86_64-linux" ];
      };
    });
in
{
  # Version-matched to what nixpkgs builds from source, so nothing else in the
  # closure notices the swap.
  nccl = mkNvidiaWheel {
    pname = "nccl";
    version = "2.32.3";
    subdir = "nvidia/nccl";
    url = "https://files.pythonhosted.org/packages/5b/29/6b277e63c92d91f9cb4d1a3a554e148983de39d54baa652bb52c798af78e/nvidia_nccl_cu13-2.32.3-py3-none-manylinux_2_27_x86_64.whl";
    hash = "sha256-FFlyMICsiJ1zom7fo+BDg6eSirMayPDsQ7PqlUiwT/M=";
    description = "NVIDIA Collective Communications Library, from NVIDIA's PyPI wheel";
  };

  libnvshmem = mkNvidiaWheel {
    pname = "libnvshmem";
    version = "3.6.5";
    subdir = "nvidia/nvshmem";
    url = "https://files.pythonhosted.org/packages/5d/7b/2ab033584a3339552472ac8d79543c503a0e06dd0d082448b06697e7f716/nvidia_nvshmem_cu13-3.6.5-py3-none-manylinux2014_x86_64.manylinux_2_17_x86_64.whl";
    hash = "sha256-QAGqvHLq0y7MPJrdPGeBvvy3Gty+KG1/WVYELmhmjHA=";
    # Every one of these belongs to a multi-node transport or bootstrap plugin
    # -- InfiniBand GPUDirect Async, MPI, OpenSHMEM, UCX, libfabric, PMIx --
    # dlopened only when that transport is selected. FreeToken serves from one
    # GPU, so none of them is ever loaded.
    ignoreMissingDeps = [
      "libfabric.so.1"
      "libmlx5.so.1"
      "libmpi.so.40"
      "liboshmem.so.40"
      "libpmix.so.2"
      "libucp.so.0"
      "libucs.so.0"
    ];
    description = "NVIDIA OpenSHMEM library, from NVIDIA's PyPI wheel";
  };
}
