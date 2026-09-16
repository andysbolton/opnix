{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.onepassword-secrets;

  resolveHomeSecretPath = name: secret: let
    secretPath =
      if secret.path != null
      then secret.path
      else name;
    secretPathStr = toString secretPath;
  in
    if builtins.substring 0 1 secretPathStr == "/"
    then secretPathStr
    else "${config.home.homeDirectory}/${secretPathStr}";

  # Validate that secret keys use proper Nix variable naming (camelCase)
  # Valid: databasePassword, sslCert, myApiKey
  # Invalid: "database/password", "ssl-cert", "my_api_key"
  isValidNixVariableName = key:
    builtins.match "^[a-z][a-zA-Z0-9]*$" key != null;

  # Validate all secret keys
  validateSecretKeys = secrets: let
    invalidKeys = lib.filter (key: !isValidNixVariableName key) (lib.attrNames secrets);
  in
    if invalidKeys != []
    then throw "Invalid secret key names. OpNix requires camelCase variable names like 'databasePassword', not path-like strings. Invalid keys: ${lib.concatStringsSep ", " invalidKeys}"
    else secrets;

  # Create a new pkgs instance with our overlay
  pkgsWithOverlay = import pkgs.path {
    system = pkgs.stdenv.hostPlatform.system;
    overlays = [
      (final: prev: {
        opnix = import ./package.nix {pkgs = final;};
      })
    ];
  };

  # Format type for secrets with home directory expansion
  secretType = lib.types.submodule {
    options = {
      path = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Path where the secret will be stored.
          Relative paths are resolved from the home directory, while absolute paths are used as-is.
          If null, uses the secret name. For example: ".config/Yubico/u2f_keys", ".ssh/id_rsa", or "/run/secrets/user/api-key"
        '';
        example = ".config/Yubico/u2f_keys";
      };

      reference = lib.mkOption {
        type = lib.types.str;
        description = "1Password reference in the format op://vault/item/field or op://vault/item/filename";
        example = "op://Personal/ssh-key/private-key";
      };

      kind = lib.mkOption {
        type = lib.types.enum ["field" "file"];
        default = "field";
        description = "Whether to resolve a text field or download a Document/attachment as raw bytes";
      };

      owner = lib.mkOption {
        type = lib.types.str;
        default = config.home.username;
        description = "User who owns the secret file (defaults to home user)";
      };

      group = lib.mkOption {
        type = lib.types.str;
        default =
          if pkgs.stdenv.isDarwin
          then "staff"
          else "users";
        description = "Group that owns the secret file";
      };

      mode = lib.mkOption {
        type = lib.types.str;
        default = "0600";
        description = "File permissions in octal notation";
        example = "0644";
      };
    };
  };
in {
  options.programs.onepassword-secrets = {
    enable = lib.mkEnableOption "1Password secrets integration";

    configFiles = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [];
      description = "List of secrets configuration files (GitHub #3)";
      example = [./personal-secrets.json ./work-secrets.json];
    };

    tokenFile = lib.mkOption {
      type = lib.types.path;
      default = "/etc/opnix-token";
      description = ''
        Path to file containing the 1Password service account token.
        The file should contain only the token and should have appropriate permissions (640).

        You can set up the token using the opnix CLI:
          opnix token set
          # or with a custom path:
          opnix token set -path /path/to/token
      '';
    };

    secrets = lib.mkOption {
      type = lib.types.attrsOf secretType;
      default = {};
      description = ''
        Declarative secrets configuration (GitHub #11).
        Keys are secret names, values are secret configurations.
        Relative paths are resolved from the home directory.
        Absolute paths are used as-is.
      '';
      example = {
        sshPrivateKey = {
          reference = "op://Personal/SSH/private-key";
          kind = "file";
          path = ".ssh/id_rsa";
          mode = "0600";
        };
        configApiKey = {
          reference = "op://Work/API/key";
          path = ".config/myapp/api-key";
          mode = "0640";
        };
      };
    };

    secretPaths = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = ''
        Computed paths for declarative secrets (GitHub #11).
        This is automatically populated and provides declarative references
        to secret file paths for use in other configuration sections.
      '';
    };

    service = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        visible = false;
        description = ''
          Deprecated and ignored. A supervised service runs the retrieval
          wherever the platform provides one (a systemd user unit on Linux, a
          launchd agent on Darwin); activation is the fallback when it does not.
        '';
      };
    };
  };

  config = lib.mkMerge [
    # Always define secretPaths to prevent evaluation errors (fixes GitHub issue)
    {
      programs.onepassword-secrets.secretPaths =
        if cfg.enable && cfg.secrets != {}
        then
          lib.mapAttrs (
            name: secret: let
              secretPath = resolveHomeSecretPath name secret;
            in
              secretPath
          )
          (validateSecretKeys cfg.secrets)
        else {};
    }

    # Main configuration only when enabled
    (lib.mkIf cfg.enable (let
      # Validate configuration
      hasMultipleConfigs = cfg.configFiles != [];
      hasDeclarativeSecrets = cfg.secrets != {};

      # At least one configuration method must be specified
      configCount = lib.length (lib.filter (x: x) [hasMultipleConfigs hasDeclarativeSecrets]);

      # Generate a temporary config file from declarative secrets
      declarativeConfigFile =
        if hasDeclarativeSecrets
        then
          pkgs.writeText "hm-opnix-declarative-secrets.json" (builtins.toJSON {
            secrets =
              lib.mapAttrsToList (name: secret: {
                path =
                  if secret.path != null
                  then secret.path
                  else name;
                reference = secret.reference;
                kind = secret.kind;
                owner = secret.owner;
                group = secret.group;
                mode = secret.mode;
              })
              (validateSecretKeys cfg.secrets);
          })
        else null;

      # Collect all config files
      allConfigFiles = lib.filter (f: f != null) (
        cfg.configFiles
        ++ (lib.optional hasDeclarativeSecrets declarativeConfigFile)
      );

      # Which service manager, if any, can run the retrieval. Both options
      # already default per-platform, so no isLinux/isDarwin check is needed.
      useSystemd = config.systemd.user.enable;
      useLaunchd = config.launchd.enable;
      supervised = useSystemd || useLaunchd;

      # Activation triggers the unit rather than retrieving inline, so a switch
      # picks up secrets rotated outside Nix. Non-blocking: the unit may wait
      # on the network, which must not stall the switch.
      triggerServiceCommand =
        if useSystemd
        then "${pkgs.systemd}/bin/systemctl --user restart --no-block opnix-secrets.service"
        else "/bin/launchctl kickstart -k gui/$(id -u)/org.nix-community.home.opnix-secrets";

      serviceStatusCommand =
        if useSystemd
        then "systemctl --user status opnix-secrets"
        else "launchctl print gui/$(id -u)/org.nix-community.home.opnix-secrets";

      # A user manager cannot order units against system targets, so poll the
      # system manager instead. See containers/podman#22197. Always exits 0:
      # a network that never arrives must not stop retrieval from trying.
      waitForNetworkScript = pkgs.writeShellScript "opnix-wait-network-online" ''
        deadline=$((SECONDS + 90))
        until ${pkgs.systemd}/bin/systemctl is-active --quiet network-online.target; do
          if [ "$SECONDS" -ge "$deadline" ]; then
            echo "WARNING: network-online.target still inactive, continuing" >&2
            break
          fi
          ${pkgs.coreutils}/bin/sleep 0.5
        done
      '';

      # No set -e: every config file is attempted even after one fails. The
      # opnix exit code is preserved for RestartPreventExitStatus.
      retrieveScript = pkgs.writeShellScript "opnix-retrieve-secrets" ''
        if [ ! -f ${lib.escapeShellArg cfg.tokenFile} ]; then
          echo "WARNING: Token file ${cfg.tokenFile} does not exist!" >&2
          echo "INFO: Using existing secrets, skipping updates" >&2
          echo "INFO: Run 'opnix token set' to configure the token" >&2
          exit 0
        fi

        if [ ! -r ${lib.escapeShellArg cfg.tokenFile} ]; then
          echo "ERROR: Cannot read system token at ${cfg.tokenFile}" >&2
          echo "INFO: Make sure the system token can be accessed by your user" >&2
          exit 1
        fi

        if [ ! -s ${lib.escapeShellArg cfg.tokenFile} ]; then
          echo "ERROR: Token file is empty!" >&2
          echo "INFO: Run 'opnix token set' to configure the token" >&2
          exit 1
        fi

        status=0

        ${lib.concatMapStringsSep "\n" (configFile: ''
            echo "Processing config file: ${configFile}"
            ${pkgsWithOverlay.opnix}/bin/opnix secret \
              -token-file ${lib.escapeShellArg cfg.tokenFile} \
              -config ${configFile} \
              -output "$HOME" || {
              status=$?
              echo "ERROR: Failed to retrieve secrets from ${configFile}" >&2
            }
          '')
          allConfigFiles}

        exit "$status"
      '';
    in {
      # Validation assertions
      assertions =
        [
          {
            assertion = configCount > 0;
            message = "OpNix Home Manager: At least one of configFiles or secrets must be specified";
          }
        ]
        ++ (lib.flatten (lib.mapAttrsToList (name: secret: [
            {
              assertion = builtins.match "^[0-7]{3,4}$" secret.mode != null;
              message = "OpNix secret '${name}': mode '${secret.mode}' is not a valid octal permission (e.g., 0644, 0600)";
            }
          ])
          cfg.secrets));

      warnings = lib.optional (!cfg.service.enable) ''
        programs.onepassword-secrets.service.enable is deprecated and ignored.
        OpNix uses a supervised service wherever one is available, and falls
        back to activation otherwise.
      '';

      # Main configuration
      home.packages = [pkgsWithOverlay.opnix];

      # Create necessary directories for declarative secrets
      home.activation.createOpnixDirs = lib.hm.dag.entryBefore ["checkLinkTargets"] ''
        # Create parent directories for all declarative secrets
        ${lib.concatMapStringsSep "\n" (name: let
          secret = cfg.secrets.${name};
          secretPath = resolveHomeSecretPath name secret;
        in ''
          $DRY_RUN_CMD mkdir -p ${lib.escapeShellArg (builtins.dirOf secretPath)}
        '') (builtins.attrNames cfg.secrets)}
      '';

      # Must follow reloadSystemd, or the trigger below restarts the old unit.
      home.activation.retrieveOpnixSecrets =
        lib.hm.dag.entryAfter (["createOpnixDirs"] ++ lib.optional useSystemd "reloadSystemd")
        (
          if supervised
          then ''
            $DRY_RUN_CMD ${triggerServiceCommand} || {
              echo "WARNING: Could not trigger the opnix-secrets service" >&2
              echo "INFO: Check it with: ${serviceStatusCommand}" >&2
            }
          ''
          else ''
            # A retrieval failure must not abort the remaining activation steps.
            $DRY_RUN_CMD ${retrieveScript} || {
              echo "INFO: Using existing secrets, skipping updates" >&2
            }
          ''
        );

      systemd.user.services.opnix-secrets = lib.mkIf useSystemd {
        Unit = {
          Description = "OpNix Secret Management";
          StartLimitIntervalSec = "1h";
          StartLimitBurst = 2;
        };
        Service = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStartPre = "${waitForNetworkScript}";
          ExecStart = "${retrieveScript}";
          # Must cover the network wait as well as retrieval.
          TimeoutStartSec = "5min";
          Restart = "on-failure";
          RestartSec = "15min";
          RestartPreventExitStatus = "65 75";
        };
        Install.WantedBy = ["default.target"];
      };

      launchd.agents.opnix-secrets = {
        enable = useLaunchd;
        config = {
          ProgramArguments = ["${retrieveScript}"];
          RunAtLoad = true;
          KeepAlive.SuccessfulExit = false;
        };
      };
    }))
  ];
}
