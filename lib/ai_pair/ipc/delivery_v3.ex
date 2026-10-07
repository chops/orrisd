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
  alias AiPair.Delivery.{ReceiptLog, ReceiptStore}

  @identity_free_outcomes ["absent", "conflict"]

  @typedoc """
  What the server supplies: the receipt store, whether this daemon is durable (durable mode with a
  boot generation), the committed intent record of a pane, the current pid of a pane from one
  census, and optionally the build identity record read at server start (`AiPair.BuildIdentity`).
  """
  @type context :: %{
          optional(:build_identity) => map() | nil,
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
        "release" -> release(params, context)
        "quiesce" -> quiesce(params, context)
        "resume" -> resume(params, context)
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
          capabilities: ["delivery_reconcile", "pane_identity", "release", "sessions_read"]
        }
        |> with_quiesce(context)
        |> with_build_identity(context)

      true ->
        with_build_identity(
          %{
            ok: true,
            pong: AiPair.version(),
            capabilities: ["delivery_reconcile", "sessions_read"]
          },
          context
        )
    end
  end

  # NS-32.M.001 RB-1: a record read at server start is reported with its token; without one,
  # neither the token nor the object is sent (vendored ipc-v3.org, "build_identity").
  defp with_build_identity(reply, %{build_identity: identity}) when is_map(identity) do
    reply
    |> Map.put(:build_identity, identity)
    |> Map.update!(:capabilities, &Enum.sort(["build_identity" | &1]))
  end

  defp with_build_identity(reply, _context), do: reply

  # NS-32.M.002 RB-3a: a durable daemon with an admission server advertises quiesce; while a fence
  # is held its ping also carries quiesced and the fence id (never the digest or the secret).
  defp with_quiesce(reply, %{admission: admission}) when not is_nil(admission) do
    reply = Map.update!(reply, :capabilities, &Enum.sort(["quiesce" | &1]))

    case AiPair.Admission.fence(admission) do
      nil -> reply
      fence_id -> Map.merge(reply, %{quiesced: true, fence_id: fence_id})
    end
  end

  defp with_quiesce(reply, _context), do: reply

  defp quiesce(params, %{admission: admission} = context) when not is_nil(admission) do
    if context.durable do
      case AiPair.Admission.quiesce(admission, params["resume_hash"]) do
        {:ok, %{fence_id: fence_id, observation: observation}} ->
          %{ok: true, quiesced: true, fence_id: fence_id, observation: observation}

        {:error, {:quiesce_timeout, bound_ms}} ->
          %{ok: false, error: "quiesce_timeout", bound_ms: bound_ms}

        {:error, {:observation_incomplete, dimension}} ->
          %{ok: false, error: "observation_incomplete", dimension: dimension}

        {:error, reason} when reason in [:quiesce_busy, :invalid_request] ->
          %{ok: false, error: Atom.to_string(reason)}
      end
    else
      unavailable()
    end
  end

  defp quiesce(_params, _context), do: %{ok: false, error: "unknown command"}

  defp resume(params, %{admission: admission}) when not is_nil(admission) do
    case AiPair.Admission.resume(admission, params["fence_id"], params["resume_secret"]) do
      :ok -> %{ok: true, resumed: true}
      {:error, :fence_mismatch} -> %{ok: false, error: "fence_mismatch"}
    end
  end

  defp resume(_params, _context), do: %{ok: false, error: "unknown command"}

  # A send or release not yet started is refused quiescing while a fence is held or a quiesce
  # drains; otherwise it runs under an admission ticket (no admission server: runs directly).
  defp admitted(context, kind, fun) do
    case AiPair.Admission.run(Map.get(context, :admission), kind, fun) do
      {:ok, result} -> result
      {:error, :quiescing} -> %{ok: false, error: "quiescing"}
    end
  end

  # NS-15.G.003 S3a: release a boot-restored quarantined pane (vendored ipc-v3.org "Release").
  # Legacy mode, a missing or invalid pane id, and an unprovable identity refuse before any
  # fence; the transaction itself is AiPair.PaneRestore.Release.run/3.
  defp release(params, context) do
    pane = params["pane_id"]

    cond do
      is_nil(pane) ->
        %{ok: false, error: "missing_pane_id"}

      not ReceiptLog.valid_pane?(pane) ->
        %{ok: false, error: "invalid_pane_id"}

      not context.durable ->
        unavailable()

      true ->
        prove = fn ->
          with {:ok, _child} <- child(pane), do: identity(pane, context)
        end

        admitted(context, :release, fn -> AiPair.PaneRestore.Release.run(pane, context, prove) end)
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

        admitted(context, :ipc_send, fn ->
          if context.durable,
            do: fenced(pane, fn -> fenced_send(params, pane, context) end),
            else: unavailable()
        end)

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

  # S3a: a pane held after an unacknowledged gated transaction (effect_unresolved) proves no
  # identity until it is resolved (RED R12).
  defp identity(pane, context) do
    with :ok <- effect_resolved(pane, context.receipt_store),
         {:ok, id} when is_binary(id) <- PaneSupervisor.registration(pane),
         {:ok, %{"registration_id" => ^id, "session_gen" => generation}} <- context.committed.(pane) do
      {:ok, %{pane_id: pane, registration_id: id, generation: generation}}
    else
      _ -> :unavailable
    end
  end

  # Fail-closed: only a live store that lists the pane as NOT unresolved lets the identity
  # proof continue. An absent or unavailable store, or one that cannot answer, cannot rule out
  # an uncleared begin, so it proves no identity.
  defp effect_resolved(_pane, nil), do: :unresolved

  defp effect_resolved(pane, store) do
    if pane in ReceiptStore.effect_status(store).unresolved, do: :unresolved, else: :ok
  catch
    :exit, _ -> :unresolved
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
