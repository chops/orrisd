defmodule AiPair.IPC.DeliveryV3 do
  @moduledoc """
  IPC protocol version 3, the identity core (vendored `docs/contracts/ipc-v3.org`; NS-15.G.002
  B1a-2): `ping`, `status`, `send` and `reconcile` with `pane_identity`, and the typed refusal
  `pane_identity_unavailable`. `cancel` and `subscribe` are not implemented and not advertised.

  A pane identity is `{pane_id, registration_id, generation}`. It is reported only when the pane's
  live child holds a registration id (its registry value, `PaneSupervisor.registration/1`) that is
  EQUAL to the `registration_id` of the pane's committed intent record, in durable mode;
  `generation` is that record's `session_gen`. An id no record holds (a failed intent write), a
  null or 1.0 record, a mismatch, an unavailable store or legacy mode are all
  `pane_identity_unavailable`: a reply never names an identity it cannot prove committed.

  Every pane-bound command runs inside `Coordinator.transaction/2` for its pane, the same fence
  durable attach, detach and re-admission hold, so the identity read and the effect it guards see
  one registration:

    * `send`: the identity is checked FIRST; on refusal nothing has been read or changed (no
      receipt, no queue entry, no paste). Only then the shared version 2 send core runs, and its
      reply carries that identity.
    * `reconcile`: the read-only classification runs first. `absent` and `conflict` name no
      registration and answer without an identity and without demanding a child (ipc-v3.org,
      "Which replies carry pane_identity"); every other outcome requires the committed identity.
    * `status`: the current `pane_pid` is measured by one tmux census under the fence; a census
      that cannot observe the pane refuses rather than report a historical pid.

  A fence that cannot be acquired cannot prove an identity, so it refuses
  `pane_identity_unavailable` too.
  """

  alias AiPair.IPC.Delivery
  alias AiPair.Pane.StateMachine
  alias AiPair.PaneSupervisor
  alias AiPair.PaneRestore.Coordinator
  alias AiPair.Delivery.ReceiptLog

  @identity_free_outcomes ["absent", "conflict"]

  @typedoc """
  What the server supplies: the receipt store, whether this daemon is durable (durable mode with a
  boot generation), the committed intent record of a pane, and the current pid of a pane from one
  census.
  """
  @type context :: %{
          receipt_store: GenServer.server() | nil,
          durable: boolean(),
          committed: (String.t() -> {:ok, map()} | :none | :error),
          current_pid: (String.t() -> {:ok, pos_integer()} | :error)
        }

  @spec dispatch(map(), context()) :: map()
  def dispatch(params, context) do
    result =
      case params["cmd"] do
        "ping" -> ping(context)
        "status" -> status(params, context)
        "send" -> send_text(params, context)
        "reconcile" -> reconcile(params, context)
        _ -> %{ok: false, error: "unknown command"}
      end

    Map.merge(result, Delivery.echo(params, 3))
  catch
    :exit, _ -> Map.merge(%{ok: false, error: "delivery_unavailable"}, Delivery.echo(params, 3))
  end

  defp ping(context) do
    cond do
      not Delivery.available?(context.receipt_store) ->
        %{ok: false, error: "receipt_store_unavailable"}

      context.durable ->
        %{
          ok: true,
          pong: AiPair.version(),
          capabilities: ["delivery_reconcile", "pane_identity", "sessions_read"]
        }

      true ->
        %{ok: true, pong: AiPair.version(), capabilities: ["delivery_reconcile", "sessions_read"]}
    end
  end

  defp status(params, context) do
    pane = params["pane_id"]

    cond do
      is_nil(pane) -> %{ok: false, error: "missing_pane_id"}
      not ReceiptLog.valid_pane?(pane) -> %{ok: false, error: "invalid_pane_id"}
      not context.durable -> unavailable()
      true -> fenced(pane, fn -> fenced_status(pane, context) end)
    end
  end

  defp fenced_status(pane, context) do
    with {:ok, child} <- child(pane),
         {:ok, identity} <- identity(pane, context),
         {:ok, pane_pid} <- context.current_pid.(pane),
         {:ok, snapshot} <- snapshot(child) do
      %{
        ok: true,
        state: Atom.to_string(snapshot.state),
        quarantined: snapshot.quarantined,
        queue_depth: snapshot.pending_count,
        pane_pid: pane_pid,
        pane_identity: identity
      }
    else
      :no_child -> %{ok: false, error: "pane_not_found"}
      _unprovable -> unavailable()
    end
  end

  defp send_text(params, context) do
    case Delivery.request_refusal(params, "send") do
      nil ->
        pane = params["pane_id"]

        if context.durable,
          do: fenced(pane, fn -> fenced_send(params, pane, context) end),
          else: unavailable()

      refusal ->
        refusal
    end
  end

  # The identity is proved before ANY effect; the v2 send core runs only after it, and a new
  # attempt is admitted bound to that identity's registration pair (B1b).
  defp fenced_send(params, pane, context) do
    with {:ok, _child} <- child(pane),
         {:ok, identity} <- identity(pane, context) do
      binding = Map.take(identity, [:registration_id, :generation])

      params
      |> Delivery.send_core(context.receipt_store, binding)
      |> with_identity(identity)
    else
      :no_child -> %{ok: false, error: "pane_not_found"}
      _unprovable -> unavailable()
    end
  end

  defp reconcile(params, context) do
    case Delivery.request_refusal(params, "reconcile") do
      nil ->
        pane = params["pane_id"]

        if context.durable,
          do: fenced(pane, fn -> fenced_reconcile(params, pane, context) end),
          else: unavailable()

      refusal ->
        refusal
    end
  end

  # Read-only classification first; only an outcome that names a registration needs one.
  defp fenced_reconcile(params, pane, context) do
    case Delivery.reconcile_core(params, context.receipt_store) do
      %{ok: true, outcome: outcome} = reply when outcome in @identity_free_outcomes ->
        reply

      %{ok: true} = reply ->
        case identity(pane, context) do
          {:ok, identity} -> with_identity(reply, identity)
          _unprovable -> unavailable()
        end

      refusal ->
        refusal
    end
  end

  defp with_identity(%{ok: true} = reply, identity), do: Map.put(reply, :pane_identity, identity)
  defp with_identity(refusal, _identity), do: refusal

  defp identity(pane, context) do
    with {:ok, id} when is_binary(id) <- PaneSupervisor.registration(pane),
         {:ok, %{"registration_id" => ^id, "session_gen" => generation}} <- context.committed.(pane) do
      {:ok, %{pane_id: pane, registration_id: id, generation: generation}}
    else
      _ -> :unavailable
    end
  end

  defp child(pane) do
    case PaneSupervisor.whereis_pane(pane) do
      {:ok, pid} -> {:ok, pid}
      :error -> :no_child
    end
  end

  defp snapshot(child) do
    {:ok, StateMachine.status(child)}
  catch
    :exit, _ -> :error
  end

  defp fenced(pane, body) do
    case Coordinator.transaction(pane, fn -> {:ok, body.()} end) do
      {:ok, reply} -> reply
      _not_held -> unavailable()
    end
  catch
    :exit, _ -> unavailable()
  end

  defp unavailable, do: %{ok: false, error: "pane_identity_unavailable"}
end
