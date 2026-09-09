import Config

# `config/config.exs` resolves `System.get_env/2` at COMPILE time, so a
# release built without these env vars in scope would ship with the
# default endpoint baked in. This file re-resolves the env at boot,
# which is what `mix release` runs at startup and what `mix run` /
# `mix phx.server` honour in dev too.
#
# We skip OTel reconfiguration in `:test` so `config/test.exs`'s
# `traces_exporter: :none` + `span_processor: :simple` stay in effect
# for the in-process test exporter.

if config_env() != :test do
  if endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
    config :opentelemetry_exporter, otlp_endpoint: endpoint
  end

  if deploy_env = System.get_env("AI_PAIR_DEPLOY_ENV") do
    config :opentelemetry,
      resource: %{
        service: %{name: "ai-pair", namespace: "ai-pair"},
        deployment: %{environment: deploy_env}
      }
  end
end
