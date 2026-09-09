import Config

test_inbox = Path.join(System.tmp_dir!(), "ai_pair_test_#{System.pid()}")
System.put_env("AI_PAIR_INBOX", test_inbox)

config :logger, level: :warning

config :ai_pair, inbox: test_inbox

# Use the simple processor in tests so :otel_simple_processor.set_exporter/2
# (driven by AiPair.Test.OtelHelper) can pin the exporter to the calling
# test's pid synchronously. Default the exporter to :none — until a test
# calls setup_otel_capture/1, spans are dropped (no OTLP HTTP traffic).
config :opentelemetry,
  span_processor: :simple,
  traces_exporter: :none
