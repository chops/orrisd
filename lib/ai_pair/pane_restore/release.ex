defmodule AiPair.PaneRestore.Release do
  @moduledoc """
  NS-15.G.003 S3a: the version 3 `release` of a boot-restored quarantined pane (scope r12,
  "Release transitions"; Charles decisions 49 and 50).

  One Coordinator transaction for the pane, in this order; each refusal is a version 3
  reply naming the pane and carrying no identity:

    1. effect_unresolved when the pane is held after an unacknowledged gated transaction;
    2. pane_identity_unavailable unless the pane's exact {registration_id, generation} is
       proven (the DeliveryV3 identity proof, passed in as `prove`);
    3. release_fence_unavailable unless the receipt store's fence takes effect (another
       holder, a STARTED transaction, a pending fence or a held pane all refuse);
    4. release_stop_failed if the quarantined child cannot be stopped: its entries stay
       fenced, listed and queued, and it stays quarantined;
    5. a restore capability for the released child (none is needed when the pane has no
       restored entries);
    6. the released child: same registration_id, no quarantine token, and released_identity
       bound to the proof. If step 5 or 6 fails the quarantined spec is admitted again
       (release_failed_requarantined); if that also fails the pane has no child
       (release_unstarted) and its entries stay listed and queued.

  Success replies released: true, the proven pane_identity and the counts of restored
  entries matched to that pair (pasted by the released child) and held (never pasted). The
  released state is not durable: a daemon restart re-admits the pane quarantined.

  `context.release_ops` may replace `fence/1`, `stop/1`, `issue/2` and `start/2` (fault
  injection in tests); a hook answering `{:default, ...}` falls through to the real operation.
  """

  alias AiPair.Delivery.ReceiptStore
  alias AiPair.PaneRestore.Coordinator
  alias AiPair.PaneSupervisor

  # above the store's fence bound, so the caller always gets the store's terminal reply
  @fence_call_timeout_ms 10_000

  @spec run(String.t(), map(), (-> {:ok, map()} | term())) :: map()
  def run(pane, context, prove) do
    case Coordinator.transaction(pane, fn -> {:ok, under_fence(pane, context, prove)} end) do
      {:ok, reply} -> reply
      _not_held -> refusal(pane, "release_fence_unavailable")
    end
  catch
    :exit, _ -> refusal(pane, "release_fence_unavailable")
  end

  defp under_fence(pane, context, prove) do
    store = context.receipt_store
    ops = Map.get(context, :release_ops, %{})

    # The replacement options are prepared before anything changes, so a failure there
    # refuses with the quarantined child untouched.
    with :ok <- not_held(pane, store),
         {:ok, identity, provenance} <- proven(pane, prove),
         {:ok, base} <- base_opts(pane, context, provenance),
         :ok <- fence(pane, store, ops),
         :ok <- stop(pane, ops) do
      released =
        base ++
          [
            registration_id: identity.registration_id,
            released_identity: {identity.registration_id, identity.generation}
          ]

      case admit(pane, store, ops, released) do
        :ok ->
          success(pane, store, identity)

        :failed ->
          requarantine(pane, store, ops, base ++ [registration_id: identity.registration_id])
      end
    else
      {:refuse, error} -> refusal(pane, error)
    end
  end

  defp not_held(pane, store) do
    if pane in ReceiptStore.effect_status(store).unresolved,
      do: {:refuse, "effect_unresolved"},
      else: :ok
  end

  # NS-32.M.002 RB-3a GREEN-2 F-1: the prove answers the identity together with the classifier
  # provenance (agent, classifier name) of the SAME committed record that proved it, so the
  # released child's classifier is bound to the registration this release proves. A prove
  # without provenance (component tests) releases with none.
  defp proven(pane, prove) do
    case prove.() do
      {:ok, %{pane_id: ^pane, registration_id: id, generation: gen} = identity, provenance}
      when is_binary(id) and is_binary(gen) ->
        {:ok, identity, provenance}

      {:ok, %{pane_id: ^pane, registration_id: id, generation: gen} = identity}
      when is_binary(id) and is_binary(gen) ->
        {:ok, identity, nil}

      _ ->
        {:refuse, "pane_identity_unavailable"}
    end
  end

  defp fence(pane, store, ops) do
    fenced =
      hook(ops, :fence, [pane], fn ->
        Coordinator.submit(pane, store, {:fence_restore, pane, make_ref()}, @fence_call_timeout_ms)
      end)

    case fenced do
      {:ok, {:ok, _ref}} -> :ok
      _other -> {:refuse, "release_fence_unavailable"}
    end
  end

  defp stop(pane, ops) do
    result = hook(ops, :stop, [pane], fn -> PaneSupervisor.stop_pane(pane) end)

    if result == :ok, do: :ok, else: {:refuse, "release_stop_failed"}
  end

  defp base_opts(pane, context, provenance) do
    # Checked before the fence and the stop, so a refusal changes nothing. A released child
    # can deliver only through the gated tmux transaction: without a tmux adapter the
    # release is refused here rather than started with every entry held (c5 r4). F-1: a
    # two-argument pane_opts builds the options from the proved record's provenance and
    # refuses (anything but {:ok, opts}) when its classifier cannot be reproduced.
    built =
      case context.pane_opts do
        build when is_function(build, 2) -> build.(pane, provenance)
        build -> build.(pane)
      end

    case built do
      {:ok, opts} when is_list(opts) ->
        if is_nil(Keyword.get(opts, :tmux_server)),
          do: {:refuse, "release_fence_unavailable"},
          else:
            {:ok, Keyword.drop(opts, [:quarantine_token, :restore_capability, :registration_id])}

      _ ->
        {:refuse, "release_fence_unavailable"}
    end
  end

  # Issue a capability (none needed without restored entries), then start the child.
  defp admit(pane, store, ops, opts) do
    with {:ok, restore} <- capability(pane, store, ops),
         :ok <- start(pane, ops, opts ++ [receipt_store: store] ++ restore) do
      :ok
    else
      _ -> :failed
    end
  end

  defp capability(pane, store, ops) do
    ref = make_ref()

    issued =
      hook(ops, :issue, [pane, ref], fn ->
        Coordinator.submit(pane, store, {:issue_restore_capability, pane, ref}, 5_000)
      end)

    case issued do
      {:ok, {:ok, cap}} when is_binary(cap) -> {:ok, [restore_capability: cap]}
      {:ok, {:error, :no_restored_entries}} -> {:ok, []}
      _ -> :failed
    end
  end

  defp start(pane, ops, opts) do
    case hook(ops, :start, [pane, opts], fn -> PaneSupervisor.start_pane(pane, opts) end) do
      {:ok, _pid} -> :ok
      _ -> :failed
    end
  end

  # The fallback restarts the pane QUARANTINED with a fresh token and the receipt store. A
  # quarantined child needs no release capability, so issuing one is best effort: it is
  # attempted (after a fence that revokes any capability issued before the failed start) so
  # the child can pull its restored entries, and without it the entries stay listed and
  # queued, unheld. Only a failed quarantined start is release_unstarted.
  # The fence is mandatory: without it a capability issued before the failed start is not
  # proven revoked, so no fallback child starts and the pane is release_unstarted (entries
  # listed and queued). Only the capability is best effort after a successful fence.
  defp requarantine(pane, store, ops, opts) do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    with :ok <- fence(pane, store, ops) do
      restore =
        case capability(pane, store, ops) do
          {:ok, restore} -> restore
          _ -> []
        end

      case start(pane, ops, opts ++ [quarantine_token: token, receipt_store: store] ++ restore) do
        :ok -> refusal(pane, "release_failed_requarantined")
        :failed -> refusal(pane, "release_unstarted")
      end
    else
      _ -> refusal(pane, "release_unstarted")
    end
  end

  defp success(pane, store, identity) do
    pair = {identity.registration_id, identity.generation}
    entries = Map.get(ReceiptStore.restore_registry(store), pane, [])
    matched = Enum.count(entries, &({&1.registration_id, &1.generation} == pair))

    %{
      ok: true,
      released: true,
      pane_id: pane,
      pane_identity: identity,
      counts: %{matched: matched, held: length(entries) - matched}
    }
  end

  # A test hook replaces an operation; {:default, ...} runs the real one.
  defp hook(ops, name, args, default) do
    case Map.fetch(ops, name) do
      {:ok, fun} ->
        case apply(fun, args) do
          {:default, _, _} -> default.()
          {:default, _} -> default.()
          other -> other
        end

      :error ->
        default.()
    end
  end

  defp refusal(pane, error), do: %{ok: false, error: error, pane_id: pane}
end
