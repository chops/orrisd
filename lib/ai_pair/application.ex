defmodule AiPair.Application do
  @moduledoc false

  use Application

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  alias AiPair.PaneIntentStore
  alias AiPair.PaneRestore.Boot
  alias AiPair.PaneRestore.Coordinator
  alias AiPair.PaneRestore.Marker

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

        children = children(inbox, receipt_store)

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

  # The one switch, read ONCE per boot: the supervision tree a daemon runs is
  # decided here and never changes (`docs/contracts/durable-mode-configuration.org`,
  # "The one switch"). `AiPair.IPC.Server` re-reads the same key per dispatch,
  # which is why a daemon started legacy and flipped at runtime serves refusals
  # until it is restarted. Only the literal `true` is durable.
  defp children(inbox, receipt_store) do
    legacy = legacy_children(inbox, receipt_store)

    if Application.get_env(:ai_pair, :durable_attachments) == true do
      durable_children(legacy, inbox)
    else
      legacy
    end
  end

  # FROZEN. These eight entries, in this order, with these options, are the
  # legacy composition the durable-mode configuration contract pins twice over:
  # against the running `which_children` tree and against the whitespace-
  # normalised text of this file, where the block must occur EXACTLY ONCE. The
  # durable branch splices into this list rather than restating it, so there is
  # no second copy to drift (the contract's OQ-6).
  defp legacy_children(inbox, receipt_store) do
    [
      {Registry, keys: :unique, name: AiPair.Registry},
      {AiPair.Telemetry.OtelBridge, heartbeat_interval_ms: 60_000},
      {AiPair.PaneSupervisor, []},
      {AiPair.Inbox.StuckScanner, inbox: inbox},
      {AiPair.Tmux, []},
      {Task.Supervisor, name: AiPair.IPC.ConnectionSupervisor},
      {AiPair.Delivery.ReceiptStore, inbox: inbox},
      {AiPair.IPC.Server, inbox: inbox, receipt_store: receipt_store}
    ]
  end

  # The eleven-child durable list. The generation is fetched, minted if absent
  # and validated BEFORE the child list exists, so a rejected `:boot_generation`
  # reaches no child, no supervisor, no socket and no marker write. Validating
  # it only inside `AiPair.IPC.Server.start_link/1`, where it is validated
  # again, would let a whole reconciliation run and quarantine panes first.
  defp durable_children(legacy, inbox) do
    generation = boot_generation!()

    tmux = Application.get_env(:ai_pair, :tmux_server, AiPair.Tmux)
    binding = Application.get_env(:ai_pair, :project_binding)
    warn_on_binding_divergence(binding, inbox)

    store_module = Application.get_env(:ai_pair, :pane_intent_store_module, PaneIntentStore)
    fs = Application.get_env(:ai_pair, :pane_intent_store_fs, PaneIntentStore.Fs.default())
    store_opts = [root: inbox, fs: fs]

    # Only `:start` is replaced, so the supervision child keeps the store's own
    # id and its `:permanent` restart whatever module is configured.
    store_spec = %{
      Supervisor.child_spec({PaneIntentStore, store_opts}, [])
      | start: {store_module, :start_link, [store_opts]}
    }

    # A name tuple, not a pid: `Boot` resolves the store through `:global` at
    # call time, under the RESOLVED INBOX (see `warn_on_binding_divergence/2`).
    store = {:global, {PaneIntentStore, Path.expand(inbox)}}

    # The split is exact and fails loudly if the legacy list ever changes shape:
    # the first five children are shared and keep their positions, the three new
    # ones are inserted after `AiPair.Tmux` and before the connection
    # supervisor, and the IPC server gains the validated generation.
    {shared, [connections, receipts, {AiPair.IPC.Server, ipc_opts}]} = Enum.split(legacy, 5)

    shared ++
      [
        {Coordinator, []},
        store_spec,
        {Boot, store: store, root: inbox, tmux: tmux, binding: binding, callbacks: callbacks(tmux)}
      ] ++
      [
        connections,
        receipts,
        {AiPair.IPC.Server, ipc_opts ++ [boot_generation: generation]}
      ]
  end

  # `fetch_env`, not `get_env || mint`: absence and a present-but-useless value
  # must be distinguishable. `:error` is the ONLY absence and means mint; an
  # explicit `nil` or `false` is a PRESENT value that fails the decimal check
  # and fails the boot, because a configuration that names the key must name a
  # usable value.
  defp boot_generation! do
    generation =
      case Application.fetch_env(:ai_pair, :boot_generation) do
        :error -> Marker.mint_generation()
        {:ok, value} -> value
      end

    if is_binary(generation) and Regex.match?(~r/\A[0-9]+\z/, generation) do
      generation
    else
      raise ArgumentError,
            "boot_generation must be a nonempty ASCII decimal string, got: #{inspect(generation)}"
    end
  end

  # Bound to the CONFIGURED adapter, so a pane quarantined by reconciliation
  # cannot route its capture or paste at the default one.
  defp callbacks(tmux) do
    %{
      capture_fn: fn pane -> AiPair.Tmux.capture_pane(pane, [], tmux) end,
      paste_fn: fn pane, text ->
        buffer = "ai_pair_#{System.unique_integer([:positive])}"

        with :ok <- AiPair.Tmux.set_buffer(buffer, text, tmux),
             :ok <- AiPair.Tmux.paste_buffer(pane, buffer, [delete: true], tmux),
             :ok <- AiPair.Tmux.send_keys(pane, ["Enter"], tmux) do
          :ok
        end
      end
    }
  end

  # OQ-1 of the durable-mode configuration contract, made LOUD rather than
  # fatal. The store is registered under the RESOLVED inbox while durable attach
  # resolves it under the binding's `project_inbox`, so when those two disagree
  # every durable attach answers `durable_unavailable` while boot reconciliation
  # works normally - an asymmetry no reader would predict. The contract does not
  # authorise refusing the boot here ("Not promised": no validation of
  # `:project_binding` at boot; the frozen `fails_boot_closed` list does not
  # carry it), so the divergence is reported at `:warning` and OQ-1 stays open
  # for the review to settle.
  defp warn_on_binding_divergence(%{project_inbox: project_inbox}, inbox)
       when is_binary(project_inbox) do
    store_root = Path.expand(inbox)
    binding_root = Path.expand(project_inbox)

    if binding_root != store_root do
      Logger.warning(
        "durable project_binding.project_inbox resolves to #{binding_root} but the daemon " <>
          "inbox resolves to #{store_root}: the pane-intent store is registered under the " <>
          "inbox and durable attach resolves it under the binding, so every durable attach " <>
          "will answer durable_unavailable while boot reconciliation works normally"
      )
    end

    :ok
  end

  defp warn_on_binding_divergence(_binding, _inbox), do: :ok

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
