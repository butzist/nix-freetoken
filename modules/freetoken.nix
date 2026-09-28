# NixOS module for FreeToken (https://github.com/FlashML-org/FreeToken).
#
# Standalone use expects `pkgs.freetoken`, i.e. this flake's overlay applied to
# nixpkgs. Importing `nixosModules.freetoken` from the flake instead defaults
# `services.freetoken.package` to the flake's own build, so no overlay is needed.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.freetoken;

  defaultStateDir = "/var/lib/freetoken";
  defaultCacheDir = "/var/cache/freetoken";

  # `ft serve` takes plain GNU-style flags, so settings map straight onto them:
  # attribute names are the flag names without the leading dashes.
  mkFlag =
    name: value:
    if value == null || value == false then
      [ ]
    else if value == true then
      [ "--${name}" ]
    else if lib.isList value then
      lib.concatMap (v: [
        "--${name}"
        (toString v)
      ]) value
    else
      [
        "--${name}"
        (toString value)
      ];

  settingsArgs = lib.concatLists (lib.mapAttrsToList mkFlag cfg.settings);

  # cfg.model is checked by an assertion; substituting "" here keeps that
  # assertion the error the user sees instead of an eval failure in mkFlag.
  model = if cfg.model == null then "" else cfg.model;

  serveArgs = [
    "serve"
    "--model"
    model
    "--host"
    cfg.host
    "--port"
    (toString cfg.port)
  ]
  ++ settingsArgs
  ++ cfg.extraArgs;

  # Flags the dedicated options already own; setting them twice would silently
  # let the last one win.
  reservedFlags = [
    "model"
    "model-path"
    "host"
    "port"
  ];
  usedReservedFlags = lib.intersectLists reservedFlags (lib.attrNames cfg.settings);

  staticUser = cfg.user != null;
  modelIsPath = lib.hasPrefix "/" model;
in
{
  options.services.freetoken = {
    enable = lib.mkEnableOption "the FreeToken MoE inference server";

    package = lib.mkPackageOption pkgs "freetoken" { };

    model = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/lib/freetoken/models/Qwen3.6-35B-A3B";
      description = ''
        The checkpoint `ft serve` loads: a local directory (HF safetensors or
        FTW), or a Hugging Face repo id that is downloaded into
        {option}`services.freetoken.stateDir` on first start.

        A path under `/home` relaxes the unit's `ProtectHome=` to
        `read-only` so the service can actually read it.
      '';
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      example = "0.0.0.0";
      description = ''
        Address the HTTP API binds to. FreeToken serves an unauthenticated API:
        anything that can reach this address can run inference, so keep it on
        loopback unless the port is fronted by a reverse proxy that
        authenticates.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 1919;
      description = "Port the HTTP API binds to.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Open {option}`services.freetoken.port` in the firewall. The API has no
        authentication of its own.
      '';
    };

    user = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "freetoken";
      description = ''
        User to run the server as. `null` runs it under a systemd
        [DynamicUser](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#DynamicUser=),
        which is the better default unless the checkpoints live outside
        {option}`services.freetoken.stateDir` and need a stable owner.

        The account is created when this is set.
      '';
    };

    group = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = cfg.user;
      defaultText = lib.literalExpression "config.services.freetoken.user";
      description = "Group to run the server as. Only used when {option}`services.freetoken.user` is set.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = defaultStateDir;
      description = ''
        Writable state: the service's `HOME`, downloaded Hugging Face
        checkpoints and the `ft bench bw` profiles. A non-default path needs
        {option}`services.freetoken.user` set, since a DynamicUser cannot own it.
      '';
    };

    cacheDir = lib.mkOption {
      type = lib.types.str;
      default = defaultCacheDir;
      description = ''
        Writable cache for JIT-compiled kernels (Triton, torch C++ extensions,
        flashinfer). Safe to delete; it is rebuilt on the next run, at the cost
        of a slow first request. A non-default path needs
        {option}`services.freetoken.user` set.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.nullOr (
          lib.types.oneOf [
            lib.types.bool
            lib.types.int
            lib.types.float
            lib.types.str
            (lib.types.listOf (lib.types.either lib.types.str lib.types.int))
          ]
        )
      );
      default = { };
      example = lib.literalExpression ''
        {
          gpu = 1;
          "moe-backend" = "hybrid";
          "moe-cache-auto" = true;
          "max-running-requests" = 8;
          "memory-ratio" = 0.9;
          "served-model-name" = "local";
        }
      '';
      description = ''
        Flags passed to `ft serve`, keyed by flag name without the leading
        `--` (see `ft serve --help`). `true` passes the bare flag, `false` and
        `null` drop it, a list repeats the flag once per element, everything
        else is passed as `--flag value`.

        Almost nothing needs setting: dtype, attention backend, MoE backend and
        cache sizes, KV capacity and the tool-call/reasoning parsers are all
        derived from the checkpoint and the GPU.
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--enable-cache-report" ];
      description = "Extra arguments appended verbatim to the `ft serve` command line.";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        FREETOKEN_PIN_BUDGET_GB = "48";
        HF_HUB_OFFLINE = "1";
      };
      description = "Extra environment variables for the server process.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/freetoken.env";
      description = ''
        `EnvironmentFile` for the unit, for secrets that should not land in the
        world-readable Nix store — a `HF_TOKEN=` for gated checkpoints, say.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.model != null && cfg.model != "";
        message = "services.freetoken.model must be set to a checkpoint path or a Hugging Face repo id.";
      }
      {
        assertion = usedReservedFlags == [ ];
        message =
          "services.freetoken.settings must not set ${
            lib.concatMapStringsSep ", " (f: "`${f}`") usedReservedFlags
          }"
          + "; use services.freetoken.model, .host and .port instead.";
      }
      {
        assertion = staticUser || (cfg.stateDir == defaultStateDir && cfg.cacheDir == defaultCacheDir);
        message = "services.freetoken.user must be set when stateDir or cacheDir is moved off its default, because a systemd DynamicUser cannot own a pre-existing directory.";
      }
    ];

    warnings =
      lib.optional (cfg.host != "127.0.0.1" && cfg.host != "localhost" && cfg.host != "::1")
        "services.freetoken.host is ${cfg.host}: the FreeToken API has no authentication, so every client that can reach it can run inference and read the served model."
      ++
        lib.optional (!config.hardware.graphics.enable)
          "services.freetoken needs the NVIDIA userspace driver (hardware.graphics.enable = true plus hardware.nvidia.*); without it `ft serve` will not find a GPU.";

    users = lib.mkIf staticUser {
      users.${cfg.user} = {
        home = cfg.stateDir;
        isSystemUser = true;
        group = cfg.group;
      };
      groups.${cfg.group} = { };
    };

    systemd.tmpfiles.settings = lib.mkIf staticUser {
      "10-freetoken" = lib.genAttrs [ cfg.stateDir cfg.cacheDir ] (_: {
        d = {
          user = cfg.user;
          group = cfg.group;
          mode = "0700";
        };
      });
    };

    systemd.services.freetoken = {
      description = "FreeToken MoE inference server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      environment = {
        HOME = cfg.stateDir;
        XDG_CACHE_HOME = cfg.cacheDir;
        # Keep model downloads and JIT artefacts inside the dirs the unit can
        # actually write to.
        HF_HOME = "${cfg.stateDir}/huggingface";
        TRITON_CACHE_DIR = "${cfg.cacheDir}/triton";
        TORCH_EXTENSIONS_DIR = "${cfg.cacheDir}/torch_extensions";
      }
      // cfg.environment;

      serviceConfig = {
        Type = "exec";
        ExecStart = "${lib.getExe cfg.package} ${lib.escapeShellArgs serveArgs}";
        WorkingDirectory = cfg.stateDir;
        Restart = "on-failure";
        RestartSec = 5;

        User = lib.mkIf staticUser cfg.user;
        Group = lib.mkIf staticUser cfg.group;
        DynamicUser = !staticUser;
        StateDirectory = lib.mkIf (cfg.stateDir == defaultStateDir) "freetoken";
        CacheDirectory = lib.mkIf (cfg.cacheDir == defaultCacheDir) "freetoken";
        ReadWritePaths = lib.mkIf staticUser [
          cfg.stateDir
          cfg.cacheDir
        ];
        EnvironmentFile = lib.mkIf (cfg.environmentFile != null) cfg.environmentFile;

        # Expert banks are pinned in host RAM and can run to tens of gigabytes.
        LimitMEMLOCK = "infinity";

        CapabilityBoundingSet = [ "" ];
        DeviceAllow = [
          "char-nvidiactl"
          "char-nvidia-caps"
          "char-nvidia-frontend"
          "char-nvidia-uvm"
        ];
        DevicePolicy = "closed";
        LockPersonality = true;
        # Triton, numba and torch's C++ extension loader all generate code at
        # runtime, which MemoryDenyWriteExecute= breaks.
        MemoryDenyWriteExecute = false;
        NoNewPrivileges = true;
        PrivateDevices = false; # would hide /dev/nvidia*
        PrivateTmp = true;
        PrivateUsers = true;
        ProcSubset = "all"; # torch reads /proc/meminfo and /proc/cpuinfo
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = lib.mkDefault (
          if modelIsPath && lib.hasPrefix "/home/" model then "read-only" else true
        );
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        RemoveIPC = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service @resources"
          "~@privileged"
        ];
        UMask = "0077";
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

    # `ft ctl`, `ft shell` and `ft launch` for talking to the running server.
    environment.systemPackages = [ cfg.package ];
  };

  meta.maintainers = [ ];
}
