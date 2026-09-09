defmodule AiPair.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :ai_pair,
      version: @version,
      description: "Orrisd agent coordination runtime",
      package: [licenses: ["Apache-2.0"]],
      source_url: "https://github.com/chops/orrisd",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl],
      mod: {AiPair.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.3"},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_exporter, "~> 1.8"}
    ]
  end

  defp releases do
    [
      ai_pair: [
        include_executables_for: [:unix],
        applications: [ai_pair: :permanent],
        overlays: ["rel/overlays"],
        steps: [:assemble, &write_cookie/1, &copy_manifest/1]
      ]
    ]
  end

  defp copy_manifest(release) do
    # __DIR__ is resolved at compile time and pinned to this mix.exs's
    # location, which is stable in Nix builders and inside `mix release`.
    # File.cwd!() would point at whatever the caller cd'd to.
    src = Path.join([__DIR__, "nix", "manifest.json"])
    dst_dir = Path.join([release.path, "share", "ai-pair"])
    File.mkdir_p!(dst_dir)
    File.cp!(src, Path.join(dst_dir, "manifest.json"))
    release
  end

  # Pin a deterministic cookie so the release is reproducible (Nix builds).
  # We never enable Erlang distribution — IPC is UDS only — so the cookie
  # value has no security relevance. Without this file, `bin/ai_pair`'s
  # start script logs `cat: releases/COOKIE: No such file or directory`
  # and exports an empty cookie.
  defp write_cookie(release) do
    File.write!(Path.join(release.path, "releases/COOKIE"), "ai-pair-no-distribution")
    release
  end
end
