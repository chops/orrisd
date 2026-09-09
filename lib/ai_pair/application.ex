defmodule AiPair.Application do
  @moduledoc false

  use Application

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  @impl true
  def start(_type, _args) do
    Tracer.with_span "daemon.start", %{
      kind: :internal,
      attributes: %{
        "daemon.inbox" => configured_inbox(),
        "daemon.version" => AiPair.version()
      }
    } do
      try do
        inbox = AiPair.Inbox.resolve!()
        Tracer.set_attribute("daemon.inbox", inbox)
        Logger.info("ai-pair starting, inbox=#{inbox}")

        maybe_attach_classifier_logger()

        receipt_store = {:global, {AiPair.Delivery.ReceiptStore, Path.expand(inbox)}}

        children = [
          {Registry, keys: :unique, name: AiPair.Registry},
          {AiPair.Telemetry.OtelBridge, heartbeat_interval_ms: 60_000},
          {AiPair.PaneSupervisor, []},
          {AiPair.Inbox.StuckScanner, inbox: inbox},
          {AiPair.Tmux, []},
          {Task.Supervisor, name: AiPair.IPC.ConnectionSupervisor},
          {AiPair.Delivery.ReceiptStore, inbox: inbox},
          {AiPair.IPC.Server, inbox: inbox, receipt_store: receipt_store}
        ]

        opts = [strategy: :one_for_one, name: AiPair.Supervisor]
        result = Supervisor.start_link(children, opts)
        annotate_boot_outcome(result)
        result
      rescue
        exception ->
          annotate_boot_error(Exception.message(exception))
          reraise exception, __STACKTRACE__
      end
    end
  end

  defp configured_inbox do
    Application.get_env(:ai_pair, :inbox) ||
      System.get_env("AI_PAIR_INBOX") ||
      AiPair.Inbox.default_path()
  end

  defp annotate_boot_outcome({:ok, _pid}) do
    Tracer.set_attribute("daemon.boot_outcome", "ok")
  end

  defp annotate_boot_outcome({:error, reason}) do
    annotate_boot_error(reason)
  end

  defp annotate_boot_error(reason) do
    Tracer.set_attribute("daemon.boot_outcome", "error")
    Tracer.set_status(:error, format_reason(reason))
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp maybe_attach_classifier_logger do
    if Application.get_env(:ai_pair, :log_classifier_decisions, false) do
      AiPair.Pane.Classifier.TelemetryLogger.attach()
    end
  end
end
