defmodule AiPair.PaneRestore.ReconcilerTest do
  # R04 slice S7: AiPair.PaneRestore.Reconciler, ported from the reviewed lane
  # (integrate/boot-abc-a2-reviewed-20260913, ff8650e) onto main's typed S4
  # census, S5 Marker and S6 quarantine, and measured here WITHOUT any tmux
  # server, daemon, socket or live store:
  #
  #   * the intent store is FakeStore, an owned GenServer that answers `:list`
  #     from a script, can HOLD the fenced second read until released (the B3
  #     fence witness), and RAISES on any `{:put, _}` or `{:delete, _}` - the
  #     no-write proof is that it is still alive after every reconcile;
  #   * tmux is FakeTmux, an owned GenServer registered under a unique name that
  #     answers `:observe_panes` and `{:show_options, _, _}` from a script and
  #     raises on any option write; or, where argv and the real parser matter,
  #     AiPair.Test.ScriptedTmux over the real AiPair.Tmux adapter and a Bash
  #     stub;
  #   * the fence is the real AiPair.PaneRestore.Coordinator and the child is
  #     started through the real AiPair.PaneSupervisor with the injected
  #     capture/paste fakes every state-machine test on main uses.
  #
  # The lane's restart_restore_test.exs rows that depended on a live `-L`
  # server and the lane-only RouteGuard (its setup, the marker-adoption rows
  # and the ISOLATION CONTROLS) are not ported; their reconciliation halves are
  # the rows below. Reconciler.observe/3 from the lane is not ported either
  # (it takes a session id, which scope r10 removes), so the lane's "two REAL
  # owned boots write the marker ZERO times" row is measured through
  # reconcile/1 with the argv the scripted stub recorded.
  use ExUnit.Case, async: false

  alias AiPair.Pane.StateMachine
  alias AiPair.PaneRestore.{Coordinator, Reconciler}
  alias AiPair.PaneSupervisor
  alias AiPair.Test.{BootReportShape, ScriptedTmux}

  @option "@ai_pair_session_incarnation"
  @root "/synthetic/inbox"
  @elsewhere "/synthetic/elsewhere"
  @generation "213598703592091008239502170616955211460"
  @binding %{project: "synthetic-project", project_dir: @root, project_inbox: @root}
  @prerequisites [
    :producer_trust,
    :process_agent_binding,
    :freshness_and_revalidation,
    :observation_completeness
  ]
  @fixture_dir Path.expand("../../fixtures/contracts/boot-report", __DIR__)

  # What `show-options -v` says for an unset user option (tmux 3.7c spelling).
  @absent {:error,
           %{cmd: ["tmux", "show-options"], status: 1, stderr: "invalid option: #{@option}\n"}}
  # A show-options failure that is NOT absence: the session cannot be addressed.
  @show_failed {:error, %{cmd: ["tmux", "show-options"], status: 3, stderr: "<detail>"}}

  # ===== FakeStore =====
  #
  # Answers `:list` from `lists`, one reply per call in order; a call past the
  # script stops the process (the reconciler then sees the store as
  # unavailable, and the row's own assertions fail). `hold: n` holds the n-th
  # `:list` until `release/1`, notifying `notify` with `{:list_held, store}`
  # first. ANY write request raises: a reconciliation that writes kills this
  # process, and every row asserts it is still alive afterwards.
  defmodule FakeStore do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def calls(store), do: GenServer.call(store, :calls)
    def release(store), do: GenServer.cast(store, :release)

    @impl true
    def init(opts) do
      {:ok,
       %{
         lists: Keyword.fetch!(opts, :lists),
         hold: Keyword.get(opts, :hold),
         notify: Keyword.get(opts, :notify),
         calls: [],
         held: nil,
         n: 0
       }}
    end

    @impl true
    def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}

    def handle_call(:list, from, state) do
      n = state.n + 1

      case state.lists do
        [] ->
          {:stop, {:unscripted_list, n}, state}

        [reply | rest] ->
          state = %{state | lists: rest, n: n, calls: [:list | state.calls]}

          if n == state.hold do
            send(state.notify, {:list_held, self()})
            {:noreply, %{state | held: {from, reply}}}
          else
            {:reply, reply, state}
          end
      end
    end

    def handle_call(request, _from, _state) do
      raise "reconciliation must never write to the intent store, got: #{inspect(request)}"
    end

    @impl true
    def handle_cast(:release, %{held: {from, reply}} = state) do
      GenServer.reply(from, reply)
      {:noreply, %{state | held: nil}}
    end
  end

  # ===== FakeTmux =====
  #
  # Stands in for AiPair.Tmux under a registered name: `observe` is the list of
  # `observe_panes` replies in order, `show` maps a session id to its
  # `show_options` replies in order. A request past its script stops the
  # process. Any option WRITE raises, which is this file's independent count
  # of marker writes: zero, or the fake is dead.
  defmodule FakeTmux do
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    def requests(server), do: GenServer.call(server, :requests)

    @impl true
    def init(opts) do
      {:ok,
       %{
         observe: Keyword.get(opts, :observe, []),
         show: Keyword.get(opts, :show, %{}),
         requests: []
       }}
    end

    @impl true
    def handle_call(:requests, _from, state), do: {:reply, Enum.reverse(state.requests), state}

    def handle_call(:observe_panes, _from, state) do
      state = %{state | requests: [:observe_panes | state.requests]}

      case state.observe do
        [] -> {:stop, {:unscripted, :observe_panes}, state}
        [reply | rest] -> {:reply, reply, %{state | observe: rest}}
      end
    end

    def handle_call({:show_options, target, option} = request, _from, state) do
      state = %{state | requests: [request | state.requests]}

      case Map.get(state.show, target, []) do
        [] ->
          {:stop, {:unscripted, {:show_options, target, option}}, state}

        [reply | rest] ->
          {:reply, reply, %{state | show: Map.put(state.show, target, rest)}}
      end
    end

    def handle_call(request, _from, _state) do
      raise "reconciliation must never write a tmux option, got: #{inspect(request)}"
    end
  end

  # ===== fixture helpers =====

  # Built at runtime so no literal pane coordinate appears in this file.
  defp pane_id, do: "%" <> Integer.to_string(System.unique_integer([:positive]))

  defp own_pane(pane), do: on_exit(fn -> PaneSupervisor.stop_pane(pane) end)

  defp record(pane, overrides \\ %{}) do
    Map.merge(
      %{
        "schema_version" => "1.0",
        "pane_id" => pane,
        "agent" => "synthetic-agent",
        "classifier" => "stub",
        "project" => "synthetic-project",
        "project_dir" => @root,
        "project_inbox" => @root,
        "tmux_session" => "restore-fixture",
        "session_gen" => @generation,
        "cwd" => @root,
        "command" => "zsh",
        "pane_pid" => 4242,
        "updated_at" => "2026-09-11T00:00:00Z"
      },
      overrides
    )
  end

  defp observation(pane, session, overrides \\ %{}) do
    Map.merge(
      %{
        pane_id: pane,
        session_id: session,
        session_name: "restore-fixture",
        window_index: 0,
        pane_index: 0,
        pane_pid: 4242,
        command: "zsh",
        path: @root
      },
      overrides
    )
  end

  # One raw row of the frozen strict-census format, for the real parser.
  defp census_row(pane, session), do: "#{pane}|#{session}|restore-fixture|0|0|4242|zsh|#{@root}\n"

  defp marker_json(overrides \\ %{}) do
    %{"version" => 1, "owner_root" => @root, "session_id" => "$3", "generation" => @generation}
    |> Map.merge(overrides)
    |> Jason.encode!()
  end

  defp marker(session, overrides \\ %{}) do
    Map.merge(
      %{version: 1, owner_root: @root, session_id: session, generation: @generation},
      overrides
    )
  end

  # The bytes `show-options -v` prints for a stored value: the value plus one newline.
  defp shown(value), do: {:ok, value <> "\n"}

  defp start_store(opts) do
    start_supervised!(%{
      id: {:fake_store, System.unique_integer([:positive])},
      start: {FakeStore, :start_link, [opts]},
      restart: :temporary
    })
  end

  defp start_tmux(opts) do
    name = String.to_atom("fake_tmux_#{System.unique_integer([:positive])}")

    start_supervised!(%{
      id: name,
      start: {FakeTmux, :start_link, [Keyword.put(opts, :name, name)]},
      restart: :temporary
    })

    name
  end

  defp start_coordinator do
    start_supervised!({Coordinator, [name: Coordinator]}, restart: :temporary)
  end

  # Recording child callbacks: the ONLY route for child effects in this file.
  defp recorder do
    {:ok, agent} = start_supervised({Agent, fn -> %{captures: [], pastes: []} end})

    capture_fn = fn pane ->
      Agent.update(agent, &%{&1 | captures: [pane | &1.captures]})
      {:ok, "IDLE_MARKER"}
    end

    paste_fn = fn pane, text ->
      Agent.update(agent, &%{&1 | pastes: [{pane, text} | &1.pastes]})
      :ok
    end

    {agent, %{capture_fn: capture_fn, paste_fn: paste_fn}}
  end

  defp recorded(agent), do: Agent.get(agent, & &1)

  defp reconcile(store, tmux, callbacks, overrides \\ []) do
    Reconciler.reconcile(
      Keyword.merge(
        [store: store, root: @root, tmux: tmux, binding: @binding, callbacks: callbacks],
        overrides
      )
    )
  end

  defp own_reported!(pid) when is_pid(pid) do
    on_exit(fn ->
      if Process.alive?(pid) do
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1_000 -> raise "holder #{inspect(pid)} did not terminate; teardown is unproven"
        end
      end
    end)
  end

  # A live holder of the pane's fence, proven acquired before returning.
  defp hold_fence!(pane) do
    test = self()

    holder =
      spawn(fn ->
        Coordinator.transaction(pane, fn ->
          send(test, {:fence_held, pane})

          receive do
            :release -> {:ok, :released}
          end
        end)
      end)

    own_reported!(holder)
    assert_receive {:fence_held, ^pane}, 1_000
    holder
  end

  defp eventually(fun, deadline_ms \\ 1_000) do
    stop_at = System.monotonic_time(:millisecond) + deadline_ms

    Stream.repeatedly(fun)
    |> Enum.reduce_while(false, fn ok, _ ->
      cond do
        ok -> {:halt, true}
        System.monotonic_time(:millisecond) > stop_at -> {:halt, false}
        true -> Process.sleep(10) && {:cont, false}
      end
    end)
  end

  defp fixture(name) do
    @fixture_dir |> Path.join(name) |> File.read!() |> Jason.decode!()
  end

  defp substitute(term, subs) when is_binary(term), do: Map.get(subs, term, term)
  defp substitute(term, subs) when is_list(term), do: Enum.map(term, &substitute(&1, subs))

  defp substitute(term, subs) when is_map(term),
    do: Map.new(term, fn {k, v} -> {substitute(k, subs), substitute(v, subs)} end)

  defp substitute(term, _subs), do: term

  # ===== rows =====

  describe "POSITIVE: an agreeing record returns quarantined and the record is retained" do
    test "re-registered through the real supervisor under the fence, observed_quarantined, never dispatchable" do
      start_coordinator()
      pane = pane_id()
      own_pane(pane)
      rows = [record(pane)]
      census = [observation(pane, "$3")]

      store = start_store(lists: [{:ok, rows}, {:ok, rows}])

      tmux =
        start_tmux(
          observe: [{:ok, census}, {:ok, census}],
          show: %{"$3" => [shown(marker_json()), shown(marker_json())]}
        )

      {agent, callbacks} = recorder()

      report = reconcile(store, tmux, callbacks)

      assert [entry] = report.panes
      assert entry.pane_id == pane
      assert entry.status == :observed_quarantined
      assert entry.refusals == []
      assert entry.undischarged == @prerequisites
      assert entry.dispatchable == false
      assert report.issues == []
      assert report.root == @root
      assert report.marker_writes == 0
      assert report.marker_observation == {:observed, %{"$3" => {:observed, marker("$3")}}}

      # The child is the one every caller finds under the via name, and it is
      # quarantined: status says so, a send is refused and nothing is queued.
      assert {:ok, sm} = PaneSupervisor.whereis_pane(pane)
      assert StateMachine.status(sm).quarantined == true
      assert {:error, :pane_quarantined} = StateMachine.send_text(sm, "hello")
      assert StateMachine.pending_count(sm) == 0

      # The child polls through OUR callback, and pasted nothing.
      assert eventually(fn -> recorded(agent).captures != [] end),
             "the child never captured through the bound callback"

      assert recorded(agent).pastes == []

      # Snapshot read, then exactly one fenced re-read; no write, or the fake is dead.
      assert FakeStore.calls(store) == [:list, :list]
      assert Process.alive?(store)

      assert FakeTmux.requests(tmux) == [
               :observe_panes,
               {:show_options, "$3", @option},
               :observe_panes,
               {:show_options, "$3", @option}
             ]

      # The fence was released and the start effect settled: nothing is left
      # outstanding in the ledger and a later transaction on the pane is admitted.
      assert Coordinator.effect_workers() == {:ok, []}
      assert {:ok, :fence_free} = Coordinator.transaction(pane, fn -> {:ok, :fence_free} end)
    end

    test "the revalidating read happens INSIDE the pane fence: a competing transaction is pane_busy while it is held" do
      start_coordinator()
      pane = pane_id()
      own_pane(pane)
      rows = [record(pane)]
      census = [observation(pane, "$3")]

      # The SECOND `:list` (the fenced re-read) is held.
      store = start_store(lists: [{:ok, rows}, {:ok, rows}], hold: 2, notify: self())

      tmux =
        start_tmux(
          observe: [{:ok, census}, {:ok, census}],
          show: %{"$3" => [shown(marker_json()), shown(marker_json())]}
        )

      {_agent, callbacks} = recorder()

      task = Task.async(fn -> reconcile(store, tmux, callbacks) end)
      assert_receive {:list_held, ^store}, 2_000

      # While the re-read is held: the fence is taken (a competing body never
      # runs) and no child has been started yet.
      test = self()

      assert {:error, :pane_busy} =
               Coordinator.transaction(pane, fn ->
                 send(test, :competing_body_ran)
                 {:ok, :never}
               end)

      refute_received :competing_body_ran
      assert :error = PaneSupervisor.whereis_pane(pane)

      FakeStore.release(store)
      report = Task.await(task, 5_000)

      assert [%{pane_id: ^pane, status: :observed_quarantined}] = report.panes
      assert {:ok, _sm} = PaneSupervisor.whereis_pane(pane)
      assert Process.alive?(store)
    end
  end

  describe "a dead, stale and live intent mix (NS-15.G.001 acceptance)" do
    test "the live pane is quarantined; every other record is refused with its own finding, retained, and starts no child" do
      start_coordinator()
      live = pane_id()
      dead = pane_id()
      stale_pid = pane_id()
      stale_gen = pane_id()
      for pane <- [live, dead, stale_pid, stale_gen], do: own_pane(pane)

      rows = [
        record(live),
        record(dead),
        record(stale_pid),
        record(stale_gen, %{"session_gen" => "8"})
      ]

      census = [
        observation(live, "$3"),
        observation(stale_pid, "$3", %{pane_pid: 4343}),
        observation(stale_gen, "$3")
      ]

      store = start_store(lists: [{:ok, rows}, {:ok, rows}])

      tmux =
        start_tmux(
          observe: [{:ok, census}, {:ok, census}],
          show: %{"$3" => [shown(marker_json()), shown(marker_json())]}
        )

      {_agent, callbacks} = recorder()

      report = reconcile(store, tmux, callbacks)

      assert [
               %{pane_id: ^live, status: :observed_quarantined, refusals: []},
               %{
                 pane_id: ^dead,
                 status: :refused,
                 refusals: [{:live_absent}, {:source_unavailable, :marker}]
               },
               %{pane_id: ^stale_pid, status: :refused, refusals: [{:conflicting, :live}]},
               %{pane_id: ^stale_gen, status: :refused, refusals: [{:generation_mismatch}]}
             ] = report.panes

      # Located findings name their own pane only: the live pane, judged in the
      # same census with the same marker, carries no finding of another row's.
      assert report.issues == [
               {:source_unavailable, :marker},
               {:live_absent, dead},
               {:conflicting, :live, stale_pid},
               {:generation_mismatch, stale_gen}
             ]

      assert {:ok, _} = PaneSupervisor.whereis_pane(live)

      for pane <- [dead, stale_pid, stale_gen],
          do: assert(:error = PaneSupervisor.whereis_pane(pane))

      # Every record retained: the store saw two reads and no write.
      assert FakeStore.calls(store) == [:list, :list]
      assert Process.alive?(store)
      assert report.marker_observation == {:observed, %{"$3" => {:observed, marker("$3")}}}
    end
  end

  describe "NEGATIVE: marker findings refuse and retain, per session" do
    test "absent, foreign and malformed markers each refuse their own session's pane and are reported by exact session id" do
      absent = pane_id()
      foreign = pane_id()
      malformed = pane_id()
      for pane <- [absent, foreign, malformed], do: own_pane(pane)

      rows = [record(absent), record(foreign), record(malformed)]
      census = [observation(absent, "$4"), observation(foreign, "$6"), observation(malformed, "$7")]
      foreign_marker = marker_json(%{"session_id" => "$6", "owner_root" => @elsewhere})

      store = start_store(lists: [{:ok, rows}])

      tmux =
        start_tmux(
          observe: [{:ok, census}],
          show: %{
            "$4" => [@absent],
            "$6" => [shown(foreign_marker)],
            "$7" => [shown("not a marker")]
          }
        )

      {agent, callbacks} = recorder()

      report = reconcile(store, tmux, callbacks)

      assert [
               %{pane_id: ^absent, status: :refused, refusals: [{:marker_absent}]},
               %{pane_id: ^foreign, status: :refused, refusals: [{:marker_foreign, @elsewhere}]},
               %{
                 pane_id: ^malformed,
                 status: :refused,
                 refusals: [{:marker_malformed, "not a marker"}]
               }
             ] = report.panes

      assert report.issues == [
               {:session_issue, :marker, "$4", {:marker_absent}},
               {:session_issue, :marker, "$6", {:marker_foreign, @elsewhere}},
               {:session_issue, :marker, "$7", {:marker_malformed, "not a marker"}},
               {:marker_absent},
               {:marker_foreign, @elsewhere},
               {:marker_malformed, "not a marker"}
             ]

      assert report.marker_observation ==
               {:observed,
                %{
                  "$4" => {:observed, :absent},
                  "$6" => {:observed, marker("$6", %{owner_root: @elsewhere})},
                  "$7" => {:observed, "not a marker"}
                }}

      for pane <- [absent, foreign, malformed],
          do: assert(:error = PaneSupervisor.whereis_pane(pane))

      assert recorded(agent) == %{captures: [], pastes: []}
      # No admissible pane, so no fenced re-read and no write.
      assert FakeStore.calls(store) == [:list]
      assert Process.alive?(store)
    end

    test "B14: a well-formed local marker naming ANOTHER session refuses for the session mismatch, not live absence" do
      pane = pane_id()
      own_pane(pane)
      rows = [record(pane)]

      store = start_store(lists: [{:ok, rows}])

      tmux =
        start_tmux(
          observe: [{:ok, [observation(pane, "$6")]}],
          show: %{"$6" => [shown(marker_json(%{"session_id" => "$2"}))]}
        )

      {_agent, callbacks} = recorder()

      report = reconcile(store, tmux, callbacks)

      assert [%{pane_id: ^pane, status: :refused, refusals: refusals}] = report.panes
      assert {:session_mismatch} in refusals
      refute {:live_absent} in refusals
      assert {:session_mismatch, pane} in report.issues
      assert :error = PaneSupervisor.whereis_pane(pane)
      assert Process.alive?(store)
    end

    test "B9: with empty intent a failed show-options is a session issue naming the exact session id" do
      orphan = pane_id()
      store = start_store(lists: [{:ok, []}])

      tmux =
        start_tmux(observe: [{:ok, [observation(orphan, "$5")]}], show: %{"$5" => [@show_failed]})

      {_agent, callbacks} = recorder()

      report = reconcile(store, tmux, callbacks)

      # A live pane with no record is never invented.
      assert report.panes == []

      assert [{:session_issue, :marker, "$5", {:source_error, :marker, %{status: 3}}}] =
               report.issues

      refute Enum.any?(report.issues, &match?({:session_issue, :marker, "$50", _}, &1))

      assert {:observed, %{"$5" => {:error, %{status: 3, stderr: "<detail>"}}}} =
               report.marker_observation

      assert Process.alive?(store)
    end
  end

  describe "source failures are reported, never collapsed into an empty report" do
    test "B10: a dead census adapter is source_unavailable live and the markers are unobserved" do
      {_agent, callbacks} = recorder()
      dead_adapter = :reconciler_test_no_such_adapter

      # Empty intent: an empty pane list with the live failure standing.
      store = start_store(lists: [{:ok, []}])
      report = reconcile(store, dead_adapter, callbacks)
      assert report.panes == []
      assert report.issues == [{:source_unavailable, :live}]
      assert report.marker_observation == :unobserved

      # A record: refused for the live failure and the marker it prevented.
      pane = pane_id()
      own_pane(pane)
      store = start_store(lists: [{:ok, [record(pane)]}])
      report = reconcile(store, dead_adapter, callbacks)

      assert [
               %{
                 pane_id: ^pane,
                 status: :refused,
                 refusals: [{:source_unavailable, :live}, {:source_unavailable, :marker}]
               }
             ] = report.panes

      assert report.issues == [{:source_unavailable, :live}, {:source_unavailable, :marker}]
      assert report.marker_observation == :unobserved
      assert :error = PaneSupervisor.whereis_pane(pane)
      assert FakeStore.calls(store) == [:list]
      assert Process.alive?(store)
    end

    test "an unreadable census is source_error live with the parser's reason, and a failed invocation with the adapter's map" do
      {_agent, callbacks} = recorder()
      pane = pane_id()
      own_pane(pane)

      store = start_store(lists: [{:ok, [record(pane)]}])
      tmux = start_tmux(observe: [{:error, {:row_arity, 8, 3, 0}}])
      report = reconcile(store, tmux, callbacks)

      assert [%{status: :refused, refusals: [{:source_error, :live, {:row_arity, 8, 3, 0}}, _]}] =
               report.panes

      assert {:source_error, :live, {:row_arity, 8, 3, 0}} in report.issues
      assert report.marker_observation == :unobserved

      failed = %{cmd: ["tmux", "list-panes"], status: 1, stderr: "no server running\n"}
      store = start_store(lists: [{:ok, []}])
      tmux = start_tmux(observe: [{:error, failed}])
      report = reconcile(store, tmux, callbacks)
      assert report.panes == []
      assert report.issues == [{:source_error, :live, failed}]
      assert :error = PaneSupervisor.whereis_pane(pane)
    end

    test "B5b: an intent source that answers an error yields no rows and names the source; a dead store is unavailable" do
      {_agent, callbacks} = recorder()
      induced = %{stage: :poisoned, reason: :induced, outcome: :uncertain, cleanup_errors: []}

      store = start_store(lists: [{:error, induced}])
      tmux = start_tmux(observe: [{:ok, []}])
      report = reconcile(store, tmux, callbacks)
      assert report.panes == []
      assert report.issues == [{:source_error, :intent, induced}]
      # The census was still taken, so the marker observation is honest about it.
      assert report.marker_observation == :not_applicable
      assert FakeTmux.requests(tmux) == [:observe_panes]

      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}, 1_000

      tmux = start_tmux(observe: [{:ok, []}])
      report = reconcile(dead, tmux, callbacks)
      assert report.panes == []
      assert report.issues == [{:source_unavailable, :intent}]
    end
  end

  describe "duplicates are ambiguous, never resolved by picking one" do
    test "a pane observed twice in the census is refused as a live duplicate and starts no child" do
      start_coordinator()
      pane = pane_id()
      own_pane(pane)
      census = [observation(pane, "$3"), observation(pane, "$3", %{pane_index: 1})]

      store = start_store(lists: [{:ok, [record(pane)]}])
      tmux = start_tmux(observe: [{:ok, census}], show: %{"$3" => [shown(marker_json())]})
      {_agent, callbacks} = recorder()

      report = reconcile(store, tmux, callbacks)

      assert [%{pane_id: ^pane, status: :refused, refusals: refusals}] = report.panes
      assert {:duplicate, :live} in refusals
      assert {:duplicate, :live, pane} in report.issues
      assert :error = PaneSupervisor.whereis_pane(pane)
      assert FakeStore.calls(store) == [:list]
      assert Process.alive?(store)
    end

    test "a pane recorded twice yields two refused rows, one per record, and the duplicate is reported once" do
      pane = pane_id()
      own_pane(pane)
      rows = [record(pane), record(pane, %{"agent" => "other-agent"})]

      store = start_store(lists: [{:ok, rows}])

      tmux =
        start_tmux(
          observe: [{:ok, [observation(pane, "$3")]}],
          show: %{"$3" => [shown(marker_json())]}
        )

      {_agent, callbacks} = recorder()

      report = reconcile(store, tmux, callbacks)

      assert [
               %{pane_id: ^pane, status: :refused, refusals: [{:duplicate, :intent}]},
               %{pane_id: ^pane, status: :refused, refusals: [{:duplicate, :intent}]}
             ] = report.panes

      assert report.issues == [{:duplicate, :intent, pane}]
      assert :error = PaneSupervisor.whereis_pane(pane)
    end
  end

  describe "the coordinator fence" do
    test "a pane whose fence is held refuses fence_refused pane_busy, re-reads nothing and starts no child" do
      start_coordinator()
      pane = pane_id()
      own_pane(pane)
      _holder = hold_fence!(pane)

      store = start_store(lists: [{:ok, [record(pane)]}])

      tmux =
        start_tmux(
          observe: [{:ok, [observation(pane, "$3")]}],
          show: %{"$3" => [shown(marker_json())]}
        )

      {agent, callbacks} = recorder()

      report = reconcile(store, tmux, callbacks)

      assert [
               %{
                 pane_id: ^pane,
                 status: :refused,
                 refusals: [{:fence_refused, :pane_busy}],
                 undischarged: @prerequisites
               }
             ] =
               report.panes

      # A fence refusal is an execution refusal, never an Admission finding or a report issue.
      assert report.issues == []
      assert :error = PaneSupervisor.whereis_pane(pane)
      assert recorded(agent) == %{captures: [], pastes: []}
      assert FakeStore.calls(store) == [:list]
      assert FakeTmux.requests(tmux) == [:observe_panes, {:show_options, "$3", @option}]
      assert Process.alive?(store)
    end

    test "with no coordinator every admissible pane is fence_refused coordinator_unavailable" do
      assert Process.whereis(Coordinator) == nil
      pane = pane_id()
      own_pane(pane)

      store = start_store(lists: [{:ok, [record(pane)]}])

      tmux =
        start_tmux(
          observe: [{:ok, [observation(pane, "$3")]}],
          show: %{"$3" => [shown(marker_json())]}
        )

      {_agent, callbacks} = recorder()

      report = reconcile(store, tmux, callbacks)

      assert [
               %{
                 pane_id: ^pane,
                 status: :refused,
                 refusals: [{:fence_refused, :coordinator_unavailable}]
               }
             ] =
               report.panes

      assert :error = PaneSupervisor.whereis_pane(pane)
      assert FakeStore.calls(store) == [:list]
    end
  end

  describe "the fenced re-read refuses any divergence from the snapshot, naming the source" do
    test "B7: intent withdrawn between the snapshot and the fenced read refuses for the INTENT source" do
      start_coordinator()
      pane = pane_id()
      own_pane(pane)
      census = [observation(pane, "$3")]

      store = start_store(lists: [{:ok, [record(pane)]}, {:ok, []}])

      tmux =
        start_tmux(
          observe: [{:ok, census}, {:ok, census}],
          show: %{"$3" => [shown(marker_json()), shown(marker_json())]}
        )

      {_agent, callbacks} = recorder()

      report = reconcile(store, tmux, callbacks)

      assert [%{pane_id: ^pane, status: :refused, refusals: refusals}] = report.panes
      assert refusals == [{:source_changed, :intent}]
      assert Enum.all?(refusals, &(elem(&1, 1) == :intent))
      refute {:live_absent} in refusals
      refute {:marker_absent} in refusals
      assert :error = PaneSupervisor.whereis_pane(pane)
      assert FakeStore.calls(store) == [:list, :list]
      assert Process.alive?(store)
    end

    test "a pane gone from the census at the fenced read refuses for the LIVE source" do
      start_coordinator()
      pane = pane_id()
      own_pane(pane)
      rows = [record(pane)]

      store = start_store(lists: [{:ok, rows}, {:ok, rows}])

      tmux =
        start_tmux(
          observe: [{:ok, [observation(pane, "$3")]}, {:ok, []}],
          show: %{"$3" => [shown(marker_json())]}
        )

      {_agent, callbacks} = recorder()

      report = reconcile(store, tmux, callbacks)

      assert [%{pane_id: ^pane, status: :refused, refusals: refusals}] = report.panes
      assert {:source_changed, :live} in refusals
      assert :error = PaneSupervisor.whereis_pane(pane)
      # No session was learned at the re-read, so no marker was asked for.
      assert FakeTmux.requests(tmux) == [
               :observe_panes,
               {:show_options, "$3", @option},
               :observe_panes
             ]
    end

    test "a marker rewritten between the reads refuses for the MARKER source" do
      start_coordinator()
      pane = pane_id()
      own_pane(pane)
      rows = [record(pane)]
      census = [observation(pane, "$3")]

      store = start_store(lists: [{:ok, rows}, {:ok, rows}])

      tmux =
        start_tmux(
          observe: [{:ok, census}, {:ok, census}],
          show: %{"$3" => [shown(marker_json()), shown(marker_json(%{"generation" => "8"}))]}
        )

      {_agent, callbacks} = recorder()

      report = reconcile(store, tmux, callbacks)

      assert [%{pane_id: ^pane, status: :refused, refusals: refusals}] = report.panes
      assert {:source_changed, :marker} in refusals
      assert {:generation_mismatch} in refusals
      assert :error = PaneSupervisor.whereis_pane(pane)
      # The report's marker observation is the snapshot's, never the rewritten value.
      assert report.marker_observation == {:observed, %{"$3" => {:observed, marker("$3")}}}
    end
  end

  describe "scope is judged against the CONFIGURED binding" do
    for {field, label} <- [{"project", "B8a"}, {"project_dir", "B8b"}] do
      test "#{label}: a record whose #{field} differs from the binding is scope_mismatch with the field as text" do
        field = unquote(field)
        pane = pane_id()
        own_pane(pane)

        store = start_store(lists: [{:ok, [record(pane, %{field => "/synthetic/other"})]}])

        tmux =
          start_tmux(
            observe: [{:ok, [observation(pane, "$3")]}],
            show: %{"$3" => [shown(marker_json())]}
          )

        {_agent, callbacks} = recorder()

        report = reconcile(store, tmux, callbacks)

        assert [%{pane_id: ^pane, status: :refused, refusals: [{:scope_mismatch, ^field}]}] =
                 report.panes

        assert report.issues == [{:scope_mismatch, pane, field}]
        assert :error = PaneSupervisor.whereis_pane(pane)
        assert FakeStore.calls(store) == [:list]
      end
    end
  end

  describe "a pane already registered is not re-registered" do
    test "the fenced start request answers already_started and the row is quarantine_unavailable, the existing child untouched" do
      start_coordinator()
      pane = pane_id()
      own_pane(pane)
      rows = [record(pane)]
      census = [observation(pane, "$3")]

      {:ok, legacy} =
        PaneSupervisor.start_pane(pane,
          capture_fn: fn _ -> {:ok, "IDLE_MARKER"} end,
          paste_fn: fn _, _ -> :ok end,
          classifier: AiPair.Test.MarkerClassifier
        )

      store = start_store(lists: [{:ok, rows}, {:ok, rows}])

      tmux =
        start_tmux(
          observe: [{:ok, census}, {:ok, census}],
          show: %{"$3" => [shown(marker_json()), shown(marker_json())]}
        )

      {_agent, callbacks} = recorder()

      report = reconcile(store, tmux, callbacks)

      assert [
               %{
                 pane_id: ^pane,
                 status: :refused,
                 refusals: [{:quarantine_unavailable, {:already_started, ^legacy}}]
               }
             ] =
               report.panes

      assert {:ok, ^legacy} = PaneSupervisor.whereis_pane(pane)
      assert Process.alive?(legacy)
      assert StateMachine.status(legacy).quarantined == false
      assert Process.alive?(store)
    end
  end

  describe "caller defects raise before any source is read" do
    test "missing or wrong callbacks, an unknown option and a relative root" do
      store = start_store(lists: [])
      tmux = start_tmux(observe: [])
      {_agent, callbacks} = recorder()

      assert_raise ArgumentError, fn -> reconcile(store, tmux, %{}) end
      assert_raise ArgumentError, fn -> reconcile(store, tmux, Map.delete(callbacks, :paste_fn)) end

      assert_raise ArgumentError, fn ->
        reconcile(store, tmux, %{capture_fn: fn -> :ok end, paste_fn: callbacks.paste_fn})
      end

      assert_raise ArgumentError, fn -> reconcile(store, tmux, callbacks, extra: 1) end

      assert_raise ArgumentError, fn ->
        reconcile(store, tmux, callbacks, root: "synthetic/inbox")
      end

      assert_raise KeyError, fn -> Reconciler.reconcile(store: store, root: @root, tmux: tmux) end

      assert FakeStore.calls(store) == []
      assert FakeTmux.requests(tmux) == []
    end
  end

  describe "through the real adapter over a scripted tmux" do
    test "two boots over one marker issue zero option writes, counted from the argv the stub recorded" do
      start_coordinator()
      pane = pane_id()
      own_pane(pane)
      rows = [record(pane)]
      census = {census_row(pane, "$3"), 0}
      shown_marker = {marker_json() <> "\n", 0}

      {tmux, dir} =
        ScriptedTmux.start!([
          census,
          shown_marker,
          census,
          shown_marker,
          census,
          shown_marker,
          census,
          shown_marker
        ])

      {_agent, callbacks} = recorder()

      first = start_store(lists: [{:ok, rows}, {:ok, rows}])
      assert [%{status: :observed_quarantined}] = reconcile(first, tmux, callbacks).panes
      assert {:ok, first_child} = PaneSupervisor.whereis_pane(pane)

      # A real stop and join between the boots, not a second read.
      ref = Process.monitor(first_child)
      :ok = PaneSupervisor.stop_pane(pane)
      assert_receive {:DOWN, ^ref, :process, ^first_child, _}, 1_000

      second = start_store(lists: [{:ok, rows}, {:ok, rows}])
      assert [%{status: :observed_quarantined}] = reconcile(second, tmux, callbacks).panes
      assert {:ok, second_child} = PaneSupervisor.whereis_pane(pane)
      assert second_child != first_child

      argvs = ScriptedTmux.argvs!(dir)
      assert ScriptedTmux.calls!(dir) == 8

      refute Enum.any?(argvs, fn argv ->
               Enum.any?(argv, &(&1 in ["set", "set-option", "setw", "set-window-option"]))
             end),
             "a boot mutated a tmux option: #{inspect(argvs)}"

      assert Enum.count(argvs, &(hd(&1) == "list-panes")) == 4
      assert Enum.count(argvs, &(&1 == ["show-options", "-t", "$3", "-v", @option])) == 4
      assert Process.alive?(first) and Process.alive?(second)
    end
  end

  describe "the produced report is the boot report contract's shape" do
    test "POSITIVE CONTROL: every frozen fixture passes the lifted closed-shape check" do
      paths = @fixture_dir |> Path.join("*.json") |> Path.wildcard()
      assert length(paths) == 3

      for path <- paths,
          do: assert(:ok = BootReportShape.assert_closed_shape!(Jason.decode!(File.read!(path))))
    end

    test "NEGATIVE CONTROL: an unknown refusal head fails the lifted check" do
      report = %{
        root: @root,
        panes: [
          %{
            pane_id: pane_id(),
            status: :refused,
            refusals: [{:restored}],
            undischarged: @prerequisites,
            dispatchable: false
          }
        ],
        issues: [],
        marker_observation: :not_applicable,
        marker_writes: 0
      }

      assert_raise ExUnit.AssertionError, fn ->
        report
        |> BootReportShape.encode()
        |> BootReportShape.json_round_trip()
        |> BootReportShape.assert_closed_shape!()
      end
    end

    test "boot-report.clean.json is reproduced through the Reconciler and the real adapter, up to the pane id placeholder" do
      start_coordinator()
      pane = pane_id()
      own_pane(pane)
      rows = [record(pane)]
      census = {census_row(pane, "$3"), 0}
      shown_marker = {marker_json() <> "\n", 0}

      {tmux, _dir} = ScriptedTmux.start!([census, shown_marker, census, shown_marker])
      store = start_store(lists: [{:ok, rows}, {:ok, rows}])
      {_agent, callbacks} = recorder()

      report = reconcile(store, tmux, callbacks)
      encoded = report |> BootReportShape.encode() |> BootReportShape.json_round_trip()

      assert :ok = BootReportShape.assert_closed_shape!(encoded)
      assert substitute(encoded, %{pane => "<pane_id>"}) == fixture("boot-report.clean.json")
      assert Process.alive?(store)
    end

    test "boot-report.refusals_and_issues.json is reproduced: B3, B4, B6, B8a, B13 and B14 rows plus the B9 session issue" do
      start_coordinator()
      [a, b, c, d, e, f, orphan] = for _ <- 1..7, do: pane_id()
      for pane <- [a, b, c, d, e, f], do: own_pane(pane)
      _holder = hold_fence!(e)

      rows = [
        record(a),
        record(b),
        record(c),
        record(d, %{"project" => "other-project"}),
        record(e),
        record(f)
      ]

      # c is not in the census; the orphan in $5 has no record; sessions are
      # enumerated in census order: $3, $4, $6, $5.
      census_output =
        census_row(a, "$3") <>
          census_row(b, "$4") <>
          census_row(d, "$3") <>
          census_row(e, "$3") <> census_row(f, "$6") <> census_row(orphan, "$5")

      census = {census_output, 0}
      marker_3 = {marker_json() <> "\n", 0}
      marker_4_absent = {"invalid option: #{@option}\n", 1, :stderr}
      marker_6_names_2 = {marker_json(%{"session_id" => "$2"}) <> "\n", 0}
      marker_5_failed = {"<detail>", 3, :stderr}

      {tmux, dir} =
        ScriptedTmux.start!(
          [census, marker_3, marker_4_absent, marker_6_names_2, marker_5_failed, census, marker_3],
          socket_name: "fixture_sock"
        )

      store = start_store(lists: [{:ok, rows}, {:ok, rows}])
      {_agent, callbacks} = recorder()

      report = reconcile(store, tmux, callbacks)
      encoded = report |> BootReportShape.encode() |> BootReportShape.json_round_trip()

      assert :ok = BootReportShape.assert_closed_shape!(encoded)

      subs = %{
        a => "<pane_a>",
        b => "<pane_b>",
        c => "<pane_c>",
        d => "<pane_d>",
        e => "<pane_e>",
        f => "<pane_f>",
        Path.join(dir, "tmux") => "<tmux_bin>",
        "fixture_sock" => "<socket_name>"
      }

      assert substitute(encoded, subs) == fixture("boot-report.refusals_and_issues.json")

      # Exactly one child: a. Every other record retained, no write.
      assert {:ok, _} = PaneSupervisor.whereis_pane(a)
      for pane <- [b, c, d, e, f, orphan], do: assert(:error = PaneSupervisor.whereis_pane(pane))
      assert FakeStore.calls(store) == [:list, :list]
      assert Process.alive?(store)
      assert ScriptedTmux.calls!(dir) == 7
    end
  end
end
