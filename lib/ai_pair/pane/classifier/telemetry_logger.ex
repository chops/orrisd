defmodule AiPair.Pane.Classifier.TelemetryLogger do
  @moduledoc """
  Dev-only telemetry handler that logs every classifier-driven state
  transition to the application logger.

  Attached at boot from `AiPair.Application` when
  `:ai_pair, :log_classifier_decisions` is true (set in `config/dev.exs`).
  Production releases leave this off; OTel exporters consume the same
  `[:ai_pair, :classifier, :decision]` event independently.
  """

  require Logger

  @handler_id :ai_pair_classifier_decision_logger
  @event [:ai_pair, :classifier, :decision]

  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, nil)
  end

  @spec detach() :: :ok | {:error, :not_found}
  def detach, do: :telemetry.detach(@handler_id)

  @doc false
  def handle_event(@event, _measurements, meta, _config) do
    Logger.debug(fn ->
      "classifier decision: pane=#{meta.pane_id} agent=#{inspect(meta.agent)} " <>
        "classifier=#{inspect(meta.classifier_name)} " <>
        "#{meta.from_state} -> #{meta.to_state}"
    end)
  end
end
