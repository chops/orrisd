import Config

config :logger, level: :debug

# Print every classifier-driven state transition. Exposed only in :dev —
# production releases never attach the handler. Independent of OTel.
config :ai_pair, log_classifier_decisions: true
