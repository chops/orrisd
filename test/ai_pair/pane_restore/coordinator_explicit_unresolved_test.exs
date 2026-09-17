defmodule AiPair.PaneRestore.CoordinatorExplicitUnresolvedTest do
  # R04 / NS-15.G.000 / NS-15.G.001, separate A2 witness. Scope r2 6f5b4061:
  # an explicit unresolved body and holder loss have different dispositions
  # after the same actual pending effect replies. The frozen suites stay intact.
  use ExUnit.Case, async: false

  alias AiPair.PaneRestore.Coordinator

  @barrier_timeout 2_000
  @cleanup_timeout 6_000

  defmodule Target do
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def snapshot(target), do: GenServer.call(target, :snapshot)
    def release(target, request), do: GenServer.call(target, {:release, request})

    @impl true
    def init(parent), do: {:ok, %{parent: parent, pending: [], accepted: [], releases: 0}}

    @impl true
    def handle_call({:hold, request}, from, state) do
      # This is served-call evidence, not a queued-mailbox observation. The
      # reported caller comes from the REAL GenServer request, not the fixture.
      send(state.parent, {:a2_accepted, request, self(), elem(from, 0)})

      {:noreply,
       %{
         state
         | pending: [{request, from} | state.pending],
           accepted: [request | state.accepted]
       }}
    end

    def handle_call(:snapshot, _from, state) do
      snapshot = %{
        pending: Enum.map(state.pending, fn {request, from} -> {request, elem(from, 0)} end),
        accepted: Enum.reverse(state.accepted),
        releases: state.releases
      }

      {:reply, snapshot, state}
    end

    def handle_call({:release, request}, _from, state) do
      {answered, remaining} = Enum.split_with(state.pending, fn {ref, _} -> ref == request end)

      # Only this target answers the original from. A detached submit has no
      # observable reply value: no target nonce or private ledger message is
      # used as fictitious reply-provenance evidence.
      Enum.each(answered, fn {_ref, from} -> GenServer.reply(from, {:committed, request}) end)

      {:reply, :ok, %{state | pending: remaining, releases: state.releases + length(answered)}}
    end
  end

  setup do
    # ExUnit stops supervised children BEFORE on_exit, in reverse start order.
    # Start Coordinator first: Target shutdown releases any unanswered calls
    # before ledger shutdown. on_exit is NOT a late target-release mechanism.
    coordinator = start_supervised!({Coordinator, [name: Coordinator]}, restart: :temporary)

    # The sole private read, exclusively to own the unlinked guardian's teardown.
    # Learn/register it before any target, effect or behavioral assertion exists.
    guardian = :sys.get_state(coordinator).guardian
    on_exit({:a2_guardian, guardian}, fn -> join_owned!(guardian, :wait) end)

    counter = start_supervised!({Agent, fn -> %{forbidden: 0, other: 0, reused: 0} end})
    target = start_supervised!({Target, self()}, restart: :temporary)

    %{
      coordinator: coordinator,
      target: target,
      counter: counter,
      pane: "a2-#{System.unique_integer([:positive])}",
      request: make_ref()
    }
  end

  test "A2 explicit unresolved stays closed after its separate accepted effect replies", context do
    context = pending_under_holder!(context)
    cause = {:separate_metadata_uncertainty, make_ref()}
    holder = context.holder
    holder_ref = context.holder_ref
    token = context.token

    # Body uncertainty is distinct from the request. It is explicitly returned,
    # acknowledged by the ledger and observed before any admission probe.
    send(context.executor, {:a2_finish, token, {:unresolved, cause}})
    assert_receive {:a2_holder_result, ^token, ^holder, {:unresolved, ^cause}}, @barrier_timeout
    assert_receive {:DOWN, ^holder_ref, :process, ^holder, :normal}, @barrier_timeout

    assert_pending!(context)
    assert_closed!(context)
    other_pane = context.pane <> "-other"

    assert {:ok, :before_reply} =
             Coordinator.transaction(
               other_pane,
               counted_body(context.counter, :other, :before_reply)
             )

    assert Agent.get(context.counter, & &1.other) == 1

    reply_and_join!(context)

    # A mutant that marks the body completed also passes every PRE-release
    # assertion, because pending operations still fence it. It fails HERE.
    # There is no :pane_busy retry anywhere in this explicit-result row.
    assert_closed!(context)

    refused = Coordinator.submit_async(context.pane, context.target, {:hold, make_ref()})
    own_unexpected_effect(refused)
    assert {:error, :unresolved_operation} = refused
    assert Target.snapshot(context.target).accepted == [context.request]

    assert {:ok, :after_reply} =
             Coordinator.transaction(
               other_pane,
               counted_body(context.counter, :other, :after_reply)
             )

    assert Agent.get(context.counter, & &1) == %{forbidden: 0, other: 2, reused: 0}
  end

  test "A2 holder-loss control reopens only after the separate accepted effect replies", context do
    context = pending_under_holder!(context)
    holder = context.holder
    holder_ref = context.holder_ref
    token = context.token

    # Kill only the actually observed, fixture-owned holder. Raising/exiting
    # INSIDE the body would be caught and become explicit abort, a different path.
    Process.exit(context.executor, :kill)
    assert_receive {:DOWN, ^holder_ref, :process, ^holder, :killed}, @barrier_timeout
    refute_received {:a2_holder_result, ^token, ^holder, _}

    deadline = System.monotonic_time(:millisecond) + @barrier_timeout
    await_holder_loss!(context, deadline)
    assert Agent.get(context.counter, & &1.forbidden) == 0
    assert_pending!(context)

    reply_and_join!(context)

    # Unlike the explicit row, this successful public admission proves that
    # the pending operation was retired, not merely hidden from live inventory.
    assert {:ok, :reused} =
             Coordinator.transaction(context.pane, counted_body(context.counter, :reused, :reused))

    assert Agent.get(context.counter, & &1) == %{forbidden: 0, other: 0, reused: 1}
  end

  defp pending_under_holder!(context) do
    parent = self()
    token = make_ref()

    {holder, holder_ref} =
      spawn_monitor(fn ->
        result =
          Coordinator.transaction(context.pane, fn ->
            parent_ref = Process.monitor(parent)
            send(parent, {:a2_inside, token, self()})

            submitted =
              Coordinator.submit_async(context.pane, context.target, {:hold, context.request})

            send(parent, {:a2_submitted, token, self(), submitted})

            try do
              receive do
                {:a2_finish, ^token, result} -> result
                {:DOWN, ^parent_ref, :process, ^parent, _} -> exit(:a2_parent_lost)
              after
                5_000 -> exit(:a2_body_barrier_timeout)
              end
            after
              Process.demonitor(parent_ref, [:flush])
            end
          end)

        send(parent, {:a2_holder_result, token, self(), result})
      end)

    own_actor(holder)
    assert_receive {:a2_inside, ^token, executor}, @barrier_timeout
    own_actor(executor)

    # Learn the actual executor; do not send the release to an assumed pid.
    # In the reviewed API the body runs in the caller; running it elsewhere
    # would make submit refuse :pane_busy and is a fixture ownership failure.
    assert executor == holder
    assert_receive {:a2_submitted, ^token, ^executor, submitted}, @barrier_timeout
    own_unexpected_effect(submitted)
    assert {:ok, worker} = submitted
    worker_ref = Process.monitor(worker)
    request = context.request
    target = context.target

    assert_receive {:a2_accepted, ^request, ^target, actual_from}, @barrier_timeout
    assert actual_from == worker
    refute worker == executor
    refute worker == holder

    context =
      Map.merge(context, %{
        holder: holder,
        holder_ref: holder_ref,
        executor: executor,
        worker: worker,
        worker_ref: worker_ref,
        token: token
      })

    assert_pending!(context)
    context
  end

  defp assert_pending!(context) do
    pane = context.pane
    worker = context.worker
    assert Process.alive?(worker)
    assert {:ok, [{^pane, ^worker}]} = Coordinator.effect_workers(context.coordinator)

    assert Target.snapshot(context.target) == %{
             pending: [{context.request, worker}],
             accepted: [context.request],
             releases: 0
           }
  end

  defp assert_closed!(context) do
    assert {:error, :unresolved_operation} =
             Coordinator.transaction(context.pane, counted_body(context.counter, :forbidden, :ran))

    assert Agent.get(context.counter, & &1.forbidden) == 0
  end

  defp reply_and_join!(context) do
    worker = context.worker
    worker_ref = context.worker_ref
    assert :ok = Target.release(context.target, context.request)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, @barrier_timeout

    # Required conjunction while Target is ALIVE: actual worker normal DOWN,
    # current pending false / exactly one release, and no live carrier. Empty
    # inventory alone also describes a retained op whose worker died. The
    # explicit row proves continued closure; only the control proves retirement.
    assert Process.alive?(context.target)

    assert Target.snapshot(context.target) == %{
             pending: [],
             accepted: [context.request],
             releases: 1
           }

    assert {:ok, []} = Coordinator.effect_workers(context.coordinator)
  end

  defp await_holder_loss!(context, deadline) do
    case Coordinator.transaction(context.pane, counted_body(context.counter, :forbidden, :ran)) do
      {:error, :unresolved_operation} ->
        :ok

      {:error, :pane_busy} ->
        # The ONLY retry: the killed holder's DOWN may reach the ledger after
        # it reaches us. Never retry an admitted body or another refusal term.
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("ledger did not process the fixture holder's DOWN before the deadline")
        end

        receive do
        after
          1 -> await_holder_loss!(context, deadline)
        end

      other ->
        flunk("expected unresolved after actual holder loss, got #{inspect(other)}")
    end
  end

  defp counted_body(counter, key, value) do
    fn ->
      Agent.update(counter, &Map.update!(&1, key, fn count -> count + 1 end))
      {:ok, value}
    end
  end

  defp own_actor(pid) do
    on_exit({:a2_actor, pid}, fn -> join_owned!(pid, :terminate) end)
  end

  # Adopt any returned carrier BEFORE asserting its result. Even a mutant
  # erroneously admitting the forbidden final submit must be joined on failure.
  defp own_unexpected_effect({:ok, pid}) when is_pid(pid) do
    on_exit({:a2_effect, pid}, fn -> join_owned!(pid, :wait) end)
  end

  defp own_unexpected_effect(_other), do: :ok

  defp join_owned!(pid, action) do
    # on_exit has a different monitor owner. A fresh monitor joins an already
    # dead process with :noproc; supervising the ledger alone is insufficient.
    ref = Process.monitor(pid)
    if action == :terminate and Process.alive?(pid), do: Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      @cleanup_timeout -> raise "A2 owned #{inspect(pid)} did not join; cleanup unproven"
    end
  end
end
