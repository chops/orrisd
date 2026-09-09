import Config

config :opentelemetry,
  resource: %{
    service: %{name: "ai-pair", namespace: "ai-pair"},
    deployment: %{environment: "local"}
  },
  span_processor: :batch,
  traces_exporter: :otlp

# otlp_endpoint can be overridden at runtime via OTEL_EXPORTER_OTLP_ENDPOINT
# in config/runtime.exs — the literal here is the dev/local default.
config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: "http://localhost:4318"

import_config "#{config_env()}.exs"
