defmodule AiPair.IPC.Delivery do
  @moduledoc "Versioned delivery operations over the daemon's receipt authority."

  alias AiPair.Delivery.{Payload, ReceiptLog, ReceiptStore}
  alias AiPair.Pane.StateMachine
  require OpenTelemetry.Tracer, as: Tracer

  @max_text_bytes 524_288
  @default_wait_ms 250

  def available?(nil), do: false

  def available?(store) do
    is_binary(ReceiptStore.daemon_epoch(store))
  catch
    :exit, _ -> false
  end

  def dispatch(params, store) do
    command = if params["cmd"] in ["send", "reconcile", "ping"], do: params["cmd"], else: "unknown"
    attrs = echo(params) |> Map.new(fn {key, value} -> {"ipc." <> Atom.to_string(key), value} end)

    Tracer.with_span "ipc." <> command, %{kind: :server, attributes: attrs} do
      result = dispatch_command(params, store)
      Tracer.set_attribute("ipc.ok", result.ok)
      if not result.ok, do: Tracer.set_status(:error, result.error)
      result
    end
  end

  defp dispatch_command(params, store) do
    result =
      case params["cmd"] do
        "ping" ->
          if available?(store),
            do: %{ok: true, pong: AiPair.version(), capabilities: ["delivery_reconcile"]},
            else: %{ok: false, error: "receipt_store_unavailable"}

        "reconcile" ->
          reconcile(params, store)

        "send" ->
          send_to_pane(params, store)

        _ ->
          %{ok: false, error: "unknown command"}
      end

    Map.merge(result, echo(params))
  catch
    :exit, _ -> Map.merge(%{ok: false, error: "delivery_unavailable"}, echo(params))
  end

  def unsupported(params),
    do: Map.merge(%{ok: false, error: "unsupported_protocol_version"}, echo(params))

  defp reconcile(params, store) do
    with :ok <- identity(params),
         :ok <- hash(params["payload_hash"]),
         {:ok, view} <-
           ReceiptStore.reconcile(
             store,
             params["msg_id"],
             params["pane_id"],
             params["payload_hash"],
             wait_ms: Map.get(params, "wait_ms", @default_wait_ms)
           ) do
      fields = if view.outcome == "conflict", do: %{}, else: receipt_fields(view)
      Map.merge(fields, %{ok: true, outcome: view.outcome})
    else
      {:error, reason} -> rejection(reason)
    end
  end

  defp send_to_pane(params, store) do
    with :ok <- identity(params),
         :ok <- text(params["text"]),
         {:ok, view} <-
           ReceiptStore.reconcile(
             store,
             params["msg_id"],
             params["pane_id"],
             Payload.hash(Payload.new(params["text"])),
             wait_ms: 0
           ) do
      case view.outcome do
        "absent" -> send_to_registered_pane(params, store)
        "conflict" -> %{ok: false, error: "conflict"}
        _ -> send_result({:duplicate, view})
      end
    else
      {:error, reason} -> rejection(reason)
    end
  catch
    :exit, {:timeout, _} -> %{ok: false, error: "send_timeout"}
    :exit, _ -> %{ok: false, error: "delivery_unavailable"}
  end

  defp send_to_registered_pane(params, store) do
    case AiPair.PaneSupervisor.whereis_pane(params["pane_id"]) do
      {:ok, pane} ->
        # This read did not admit an attempt; the pane still owns atomic admission.
        timeout = Application.get_env(:ai_pair, :send_call_timeout_ms, 5_000)
        result = StateMachine.send_receipted(pane, params["text"], timeout, params["msg_id"], store)
        send_result(result)

      :error ->
        %{ok: false, error: "pane_not_found"}
    end
  end

  defp send_result(:ok), do: %{ok: true, status: "sent"}

  defp send_result({:queued, reason}) when is_atom(reason),
    do: %{ok: true, status: "queued", queue_reason: Atom.to_string(reason)}

  defp send_result({:duplicate, view}),
    do: Map.merge(receipt_fields(view), %{ok: true, duplicate: true})

  defp send_result({:error, reason}), do: rejection(reason)

  defp receipt_fields(view), do: Map.take(view, [:status, :delivery_attempt, :payload_hash])

  defp identity(params) do
    cond do
      is_nil(params["msg_id"]) -> {:error, :missing_msg_id}
      not ReceiptLog.valid_id?(params["msg_id"]) -> {:error, :invalid_msg_id}
      is_nil(params["pane_id"]) -> {:error, :missing_pane_id}
      not ReceiptLog.valid_pane?(params["pane_id"]) -> {:error, :invalid_pane_id}
      true -> :ok
    end
  end

  defp hash(nil), do: {:error, :missing_payload_hash}

  defp hash(value),
    do: if(ReceiptLog.valid_hash?(value), do: :ok, else: {:error, :invalid_payload_hash})

  defp text(value) when is_binary(value) and byte_size(value) <= @max_text_bytes, do: :ok
  defp text(value) when is_binary(value), do: {:error, :oversize}
  defp text(_), do: {:error, :missing_text}

  defp echo(params) do
    %{protocol_version: 2}
    |> maybe_echo(:msg_id, params["msg_id"], ReceiptLog.valid_id?(params["msg_id"]))
    |> maybe_echo(:pane_id, params["pane_id"], echoable_pane?(params["pane_id"]))
  end

  defp echoable_pane?(value) when is_binary(value),
    do: Regex.match?(~r/\A%[a-zA-Z0-9_-]{1,128}\z/, value)

  defp echoable_pane?(_), do: false
  defp maybe_echo(map, key, value, true), do: Map.put(map, key, value)
  defp maybe_echo(map, _key, _value, false), do: map

  @request_errors [
    :missing_msg_id,
    :invalid_msg_id,
    :missing_pane_id,
    :invalid_pane_id,
    :missing_payload_hash,
    :invalid_payload_hash,
    :missing_text,
    :oversize,
    :invalid_wait_ms,
    :pane_dead,
    :receipt_store_unavailable,
    :receipt_store_mismatch
  ]
  defp rejection(reason) when reason in @request_errors,
    do: %{ok: false, error: Atom.to_string(reason)}

  defp rejection({:conflict, _view}), do: %{ok: false, error: "conflict"}
  defp rejection({:queue_full, _cap}), do: %{ok: false, error: "queue_full"}
  defp rejection({:paste_failed, _reason}), do: %{ok: false, error: "paste_failed"}
  defp rejection(_reason), do: %{ok: false, error: "receipt_store_unavailable"}
end
