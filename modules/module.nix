moduleConfig:
{ lib, pkgs, config, ... }:

with lib;

{
  options.services.auto-fix-vscode-server = with types;{
    enable = mkEnableOption "Auto-fix service for vscode-server in NixOS";

    nodePackage = mkOption {
      type = package;
      default = pkgs.nodejs-16_x;
    };

    ripgrepPackage = mkOption {
      type = package;
      default = pkgs.ripgrep;
    };
  };

  config =
    let
      cfg = config.services.auto-fix-vscode-server;
      nodePath = "${ cfg.nodePackage }/bin/node";
      ripgrepPath = "${ cfg.ripgrepPackage }/bin/rg";
      utilsPath = makeBinPath (with pkgs; [ bash coreutils findutils inotify-tools ]);
      mkStartScript = name: pkgs.writeShellScript "${name}.sh" ''
        set -euo pipefail

        PATH=${ utilsPath }
        bin_dir=~/.vscode-server/bin

        echo "Service started…"
        echo "Fixing existing binaries in $bin_dir (if any)…"
        
        if [[ -e $bin_dir ]]; then
          find "$bin_dir" -mindepth 2 -maxdepth 2 -name node -type f -exec bash -c "echo 'Fixing {}…'; ln -sfT ${ nodePath } {}" \;
          find "$bin_dir" -path '*/@vscode/ripgrep/bin/rg' -exec bash -c "echo 'Fixing {}…'; ln -sfT ${ ripgrepPath } {}" \;
        else
          mkdir -p "$bin_dir"
        fi

        echo "Listening for events in $bin_dir…"

        while IFS=: read -r bin_dir event; do
          # A new version of the VS Code Server is being created.
          if [[ $event == 'CREATE,ISDIR' ]]; then
            echo "VSCode server is being installed at $bin_dir, fixing binaries…"

            # Create a trigger to know when their node is being created and replace it for our symlink.
            touch "$bin_dir/node"
    
            echo "Waiting for binaries to appear..."
            inotifywait -qq -e DELETE_SELF "$bin_dir/node"

            echo "Fixing $bin_dir/node…"
            ln -sfT ${ nodePath } "$bin_dir/node"
            
            echo "Fixing $bin_dir/node_modules/@vscode/ripgrep/bin/rg…"
            ln -sfT ${ ripgrepPath } "$bin_dir/node_modules/@vscode/ripgrep/bin/rg"
          # The monitored directory is deleted, e.g. when "Uninstall VS Code Server from Host" has been run.
          elif [[ $event == DELETE_SELF ]]; then
            echo "VSCode server directory is being removed, exiting…"

            # See the comments above Restart in the service config.
            exit 0
          fi
        done < <(inotifywait -q -m -e CREATE,ISDIR -e DELETE_SELF --format '%w%f:%e' "$bin_dir")
      '';
    in
      mkIf cfg.enable (
        moduleConfig rec {
          name = "auto-fix-vscode-server";
          description = "Automatically fix the VS Code server used by the remote SSH extension";
          serviceConfig = {
            # When a monitored directory is deleted, it will stop being monitored.
            # Even if it is later recreated it will not restart monitoring it.
            # Unfortunately the monitor does not kill itself when it stops monitoring,
            # so rather than creating our own restart mechanism, we leverage systemd to do this for us.
            Restart = "always";
            RestartSec = 0;
            ExecStart = "${ mkStartScript name }";
          };
        }
      );
}
