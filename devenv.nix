{ pkgs, lib, config, ... }:

{
  languages.elixir = {
    enable = true;
    package = pkgs.beam.packages.erlang_29.elixir_1_20;
  };

  # devenv 1.11 unconditionally references process.managers.process-compose.configFile
  # via PC_CONFIG_FILES, even when the manager is disabled and no processes are defined.
  # Stub the path so evaluation succeeds.
  process.managers.process-compose.configFile = lib.mkForce "/dev/null";

  packages = with pkgs; [
    git
    tmux
    coreutils
    lefthook
    ripgrep
    shellcheck
  ];

  # devenv `env` values are exported literally — shell variables like
  # $DEVENV_STATE are NOT expanded. Use Nix interpolation against
  # `config.devenv.state` so MIX_HOME/HEX_HOME end up as absolute paths.
  env = {
    MIX_HOME = "${config.devenv.state}/mix";
    HEX_HOME = "${config.devenv.state}/hex";
    ERL_AFLAGS = "-kernel shell_history enabled";
  };

  enterShell = ''
    mix local.hex --if-missing --force
    mix local.rebar --if-missing --force

    echo ""
    echo "ai-pair dev shell"
    echo "  $(elixir --version | tail -1)"
    echo "  AI_PAIR_INBOX=$AI_PAIR_INBOX"
    echo "  OTEL endpoint: $OTEL_EXPORTER_OTLP_ENDPOINT"
    echo ""
  '';
}
