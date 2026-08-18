{
  pkgs,
  nixpkgs,
  system,
  src,
  vendorHash,
}:
{
  # Run tests
  go-tests = pkgs.buildGoModule {
    pname = "opnix-go-tests";
    version = "0.10.1";
    inherit src;
    inherit vendorHash;

    checkPhase = ''
      go test ./...
    '';

    installPhase = "touch $out";
  };

  # Run golangci-lint
  go-lint = pkgs.buildGoModule {
    pname = "opnix-go-lint";
    version = "0.10.1";
    inherit src;
    inherit vendorHash;

    nativeBuildInputs = [pkgs.golangci-lint];

    buildPhase = ''
      export GOLANGCI_LINT_CACHE=$TMPDIR/golangci-lint
      export XDG_CACHE_HOME=$TMPDIR/cache

      mkdir -p $GOLANGCI_LINT_CACHE
      mkdir -p $XDG_CACHE_HOME

      ${
        let
          cfg = ''
            version: "2"
            linters:
              default: standard
              settings:
                errcheck:
                  exclude-functions:
                    - fmt.Fprintf
              exclusions:
                rules:
                  - path: ".*_test\\.go$"
                    linters:
                      - errcheck
          '';
        in "echo -n '${cfg}' >> .golangci.yaml"
      }

      golangci-lint run --allow-parallel-runners \
        --timeout=5m \
        --max-same-issues=20 \
        ./...
    '';

    installPhase = "touch $out";
  };

  # Check nix formatting
  nix-fmt-check =
    pkgs.runCommand "opnix-nix-fmt-check"
    {
      nativeBuildInputs = [pkgs.alejandra];
      inherit src;
    } ''
      cp -r $src/* .
      alejandra --check .
      touch $out
    '';
}
// (let
  lib = pkgs.lib;
  hmLib = lib.extend (_: _: {
    hm.dag = {
      entryBefore = _: value: value;
      entryAfter = _: value: value;
    };
  });
  mkHmConfig = serviceEnable:
    (hmLib.evalModules {
      specialArgs = {inherit pkgs;};
      modules = [
        ./hm-module.nix
        {
          options = {
            home.homeDirectory = lib.mkOption {type = lib.types.str;};
            home.username = lib.mkOption {type = lib.types.str;};
            home.packages = lib.mkOption {
              type = lib.types.listOf lib.types.package;
              default = [];
            };
            home.activation = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = {};
            };
            assertions = lib.mkOption {
              type = lib.types.listOf lib.types.anything;
              default = [];
            };
            warnings = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
            };
            systemd.user.enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
            systemd.user.services = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = {};
            };
            launchd.enable = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
            launchd.agents = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = {};
            };
          };
          config = {
            home.homeDirectory = "/home/opnix-test";
            home.username = "opnix-test";
            programs.onepassword-secrets = {
              enable = true;
              service.enable = serviceEnable;
              secrets = {
                defaultSecret.reference = "op://Example/Service/password";
                fileSecret = {
                  reference = "op://Example/Document/archive.bin";
                  kind = "file";
                };
              };
            };
          };
        }
      ];
    }).config;
  hmConfig = mkHmConfig false;
  hmServiceConfig = mkHmConfig true;
  darwinConfig =
    (lib.evalModules {
      specialArgs = {inherit pkgs;};
      modules = [
        ./darwin-module.nix
        {
          options = {
            assertions = lib.mkOption {
              type = lib.types.listOf lib.types.anything;
              default = [];
            };
            users.knownGroups = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
            };
            users.groups = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = {};
            };
            users.users = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = {};
            };
            launchd.daemons = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = {};
            };
            system.activationScripts.extraActivation.text = lib.mkOption {
              type = lib.types.str;
              default = "";
            };
          };
          config.services.onepassword-secrets = {
            enable = true;
            secrets = {
              defaultSecret.reference = "op://Example/Service/password";
              fileSecret = {
                reference = "op://Example/Document/archive.bin";
                kind = "file";
              };
            };
          };
        }
      ];
    }).config;
in {
  hm-module-evaluation = assert hmConfig.programs.onepassword-secrets.secrets.defaultSecret.kind == "field";
  assert hmConfig.programs.onepassword-secrets.secrets.fileSecret.kind == "file";
    pkgs.runCommand "opnix-hm-module-evaluation" {
      moduleScript = hmConfig.home.activation.retrieveOpnixSecrets;
    } ''
      retrieve_script=$(printf '%s\n' "$moduleScript" | grep -o '/nix/store/[^ ]*-opnix-retrieve-secrets' | head -n1)
      test -x "$retrieve_script"
      config_file=$(grep -o '/nix/store/[^ ]*-hm-opnix-declarative-secrets.json' "$retrieve_script" | head -n1)
      grep -Fq '"kind":"field"' "$config_file"
      grep -Fq '"kind":"file"' "$config_file"
      touch $out
    '';

  # The service takes over retrieval, and activation must stop doing it.
  hm-module-service-evaluation = let
    unit = hmServiceConfig.systemd.user.services.opnix-secrets;
  in
    assert hmServiceConfig.warnings == [];
      pkgs.runCommand "opnix-hm-module-service-evaluation" {
        execStart = unit.Service.ExecStart;
        activationScript = hmServiceConfig.home.activation.retrieveOpnixSecrets;
        preventExitStatus = unit.Service.RestartPreventExitStatus;
      } ''
        config_file=$(grep -o '/nix/store/[^ ]*-hm-opnix-declarative-secrets.json' "$execStart" | head -n1)
        grep -Fq '"kind":"field"' "$config_file"
        grep -Fq '"kind":"file"' "$config_file"

        grep -Fq 'exit "$status"' "$execStart"
        test "$preventExitStatus" = "65 75"

        if printf '%s\n' "$activationScript" | grep -q 'opnix-retrieve-secrets'; then
          echo "activation still retrieves secrets while the service is enabled" >&2
          exit 1
        fi
        touch $out
      '';

  darwin-module-evaluation = assert darwinConfig.services.onepassword-secrets.secrets.defaultSecret.kind == "field";
  assert darwinConfig.services.onepassword-secrets.secrets.fileSecret.kind == "file";
    pkgs.runCommand "opnix-darwin-module-evaluation" {
      moduleScript = builtins.elemAt darwinConfig.launchd.daemons.opnix-secrets.serviceConfig.ProgramArguments 2;
    } ''
      config_file=$(printf '%s\n' "$moduleScript" | grep -o '/nix/store/[^ ]*-opnix-declarative-secrets.json' | head -n1)
      grep -Fq '"kind":"field"' "$config_file"
      grep -Fq '"kind":"file"' "$config_file"
      touch $out
    '';
})
// pkgs.lib.optionalAttrs pkgs.stdenv.isLinux (let
  nixosConfig = polling:
    (nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        ./module.nix
        {
          system.stateVersion = "26.05";
          services.onepassword-secrets = {
            enable = true;
            secrets.testSecret.reference = "op://Example/Service/password";
            secrets.testFile = {
              reference = "op://Example/Document/archive.bin";
              kind = "file";
            };
            systemdIntegration.polling = polling;
          };
        }
      ];
    }).config;

  defaultPollingConfig = nixosConfig {};
  enabledPollingConfig = nixosConfig {
    enable = true;
    interval = "45min";
  };
in {
  module-evaluation = assert !(defaultPollingConfig.systemd.services ? opnix-secrets-poll);
  assert !(defaultPollingConfig.systemd.timers ? opnix-secrets-poll);
  assert defaultPollingConfig.services.onepassword-secrets.secrets.testSecret.kind == "field";
  assert defaultPollingConfig.services.onepassword-secrets.secrets.testFile.kind == "file";
  assert enabledPollingConfig.systemd.services.opnix-secrets-poll.serviceConfig.Type == "oneshot";
  assert !(enabledPollingConfig.systemd.services.opnix-secrets-poll.serviceConfig ? RemainAfterExit);
  assert nixpkgs.lib.hasInfix "systemctl stop opnix-secrets-watcher.path" enabledPollingConfig.systemd.services.opnix-secrets-poll.script;
  assert nixpkgs.lib.hasInfix "trap restore_watcher EXIT" enabledPollingConfig.systemd.services.opnix-secrets-poll.script;
  assert enabledPollingConfig.systemd.timers.opnix-secrets-poll.timerConfig.OnActiveSec == "45min";
  assert enabledPollingConfig.systemd.timers.opnix-secrets-poll.timerConfig.OnUnitActiveSec == "45min";
  assert enabledPollingConfig.systemd.timers.opnix-secrets-poll.timerConfig.Unit == "opnix-secrets-poll.service";
    pkgs.runCommand "opnix-module-evaluation" {
      moduleScript = defaultPollingConfig.systemd.services.opnix-secrets.script;
    } ''
      config_file=$(printf '%s\n' "$moduleScript" | grep -o '/nix/store/[^ ]*-opnix-declarative-secrets.json' | head -n1)
      grep -Fq '"kind":"field"' "$config_file"
      grep -Fq '"kind":"file"' "$config_file"
      touch $out
    '';
})
