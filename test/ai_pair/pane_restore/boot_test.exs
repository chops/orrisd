defmodule AiPair.PaneRestore.BootTest do
  # R04 slice S8: AiPair.PaneRestore.Boot, the ready-on-return child that runs
  # ONE reconciliation per durable boot, joins or terminates it at a deadline,
  # and publishes the boot report to disk.
  #
  # Ported from the reviewed lane (integrate/boot-abc-a2-reviewed-20260913,
  # ff8650e) onto main's S7 Reconciler, and measured with NO tmux server, no
  # daemon, no socket, no launchd and no live store:
  #
  #   * the intent store is FakeStore, an owned GenServer answering `:list` from
  #     a script, able to HOLD a numbered read (reporting the CALLER, which is
  #     Boot's reconciliation worker) and RAISING on any write request;
  #   * tmux is FakeTmux, an owned GenServer answering `:observe_panes` and
  #     `{:show_options, _, _}` from a script and raising on any option write;
  #     or, where the real parser and the frozen fixture bytes matter,
  #     AiPair.Test.ScriptedTmux over the real AiPair.Tmux adapter and a Bash
  #     stub;
  #   * the fence is the real AiPair.PaneRestore.Coordinator and a started child
  #     is the real AiPair.PaneSupervisor's, with injected capture/paste fakes.
  #
  # The fakes are declared here rather than shared with
  # AiPair.PaneRestore.ReconcilerTest on purpose: a focused run of this file
  # alone must not depend on another test file having been loaded first.
  #
  # Rows the audit (R04-BOOT-RESTORATION-SOURCE-GAP-AUDIT section 3.2) records
  # as blocked by Boot's absence are named in the test titles. The lane rows
  # whose demands are the IPC durable path (B13's detach halves) or the
  # Application composition (B2, B5a, B5b) belong to S9 and S10 and are not
  # here; B13's reconciliation half (a held fence refuses, never re-registers)
  # is.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias AiPair.Pane.StateMachine
  alias AiPair.PaneRestore.Boot
  alias AiPair.PaneRestore.Boot.ReportWriter
  alias AiPair.PaneRestore.Coordinator
  alias AiPair.PaneSupervisor
  alias AiPair.Test.{BootReportShape, ScriptedTmux}

  @option "@ai_pair_session_incarnation"
  @generation "213598703592091008239502170616955211460"
  @prerequisites [
    :producer_trust,
    :process_agent_binding,
    :freshness_and_revalidation,
    :observation_completeness
  ]
  @fixture_dir Path.expand("../../fixtures/contracts/boot-report", __DIR__)
  # The fixtures' placeholder root; no test may write under it.
  @fixture_root "/synthetic/inbox"

  # What `show-options -v` says for an unset user option (tmux 3.7c spelling).
  @absent {:error,
           %{cmd: ["tmux", "show-options"], status: 1, stderr: "invalid option: #{@option}\n"}}

  # ===== FakeStore =====
  #
  # `lists` is one `:list` reply per call, in order; a call past the script
  # stops the process. `hold: n` holds the n-th reply until `release/1`, first
  # telling `notify` `{:list_held, n, store, caller}` - the caller is the
  # reconciliation worker, which is how a row learns the pid Boot must join.
  # ANY write request raises: a reconciliation that wrote would kill this
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

    def handle_call(:list, {caller, _tag} = from, state) do
      n = state.n + 1

      case state.lists do
        [] ->
          {:stop, {:unscripted_list, n}, state}

        [reply | rest] ->
          state = %{state | lists: rest, n: n, calls: [:list | state.calls]}

          if n == state.hold do
            send(state.notify, {:list_held, n, self(), caller})
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

    def handle_cast(:release, state), do: {:noreply, state}
  end

  # ===== FakeTmux =====
  #
  # `observe` is the list of `observe_panes` replies in order; `show` maps a
  # session id to its `show_options` replies in order. A request past its script
  # stops the process. Any option WRITE raises: this file's independent count of
  # marker writes is zero, or the fake is dead.
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

  # ===== a report writer that is a BEHAVIOUR MODULE, not a function =====
  #
  # It records into an Agent registered under its own name, so the same
  # boundary can be proven for the module shape without a filesystem.
  defmodule ModuleWriter do
    @behaviour AiPair.PaneRestore.Boot.ReportWriterBehaviour

    def calls, do: Agent.get(__MODULE__, &Enum.reverse/1)

    @impl true
    def write(path, report) do
      Agent.update(__MODULE__, &[{path, report} | &1])
      :ok
    end
  end

  # ===== fixture helpers =====

  defp pane_id, do: "%" <> Integer.to_string(System.unique_integer([:positive]))

  defp own_pane(pane), do: on_exit(fn -> PaneSupervisor.stop_pane(pane) end)

  # A real, private, writable root: the production writer publishes under it.
  defp private_root! do
    root = Path.join(System.tmp_dir!(), "ai_pair_boot_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    root
  end

  defp binding_for(root),
    do: %{project: "synthetic-project", project_dir: root, project_inbox: root}

  defp record(pane, root, overrides \\ %{}) do
    Map.merge(
      %{
        "schema_version" => "1.0",
        "pane_id" => pane,
        "agent" => "synthetic-agent",
        "classifier" => "stub",
        "project" => "synthetic-project",
        "project_dir" => root,
        "project_inbox" => root,
        "tmux_session" => "restore-fixture",
        "session_gen" => @generation,
        "cwd" => root,
        "command" => "zsh",
        "pane_pid" => 4242,
        "updated_at" => "2026-09-11T00:00:00Z"
      },
      overrides
    )
  end

  defp observation(pane, session, root, overrides \\ %{}) do
    Map.merge(
      %{
        pane_id: pane,
        session_id: session,
        session_name: "restore-fixture",
        window_index: 0,
        pane_index: 0,
        pane_pid: 4242,
        command: "zsh",
        path: root
      },
      overrides
    )
  end

  # One raw row of the frozen strict-census format, for the real parser.
  defp census_row(pane, session, root),
    do: "#{pane}|#{session}|restore-fixture|0|0|4242|zsh|#{root}\n"

  defp marker_json(root, overrides \\ %{}) do
    %{"version" => 1, "owner_root" => root, "session_id" => "$3", "generation" => @generation}
    |> Map.merge(overrides)
    |> Jason.encode!()
  end

  defp marker(session, root, overrides \\ %{}) do
    Map.merge(
      %{version: 1, owner_root: root, session_id: session, generation: @generation},
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
    name = String.to_atom("boot_fake_tmux_#{System.unique_integer([:positive])}")

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

  defp boot_opts(store, tmux, callbacks, root, overrides \\ []) do
    Keyword.merge(
      [store: store, root: root, tmux: tmux, binding: binding_for(root), callbacks: callbacks],
      overrides
    )
  end

  # Starting through the test supervisor keeps the blocking start_link off the
  # test process, and the child is stopped for us at the end of the row.
  defp boot_spec(opts) do
    %{
      id: {:boot, System.unique_integer([:positive])},
      start: {Boot, :start_link, [opts]},
      restart: :temporary
    }
  end

  defp start_boot!(opts), do: start_supervised!(boot_spec(opts))

  # A writer that records every call into an agent and then delegates, so a row
  # can count publications of the REAL bytes.
  defp counting_writer(agent, inner \\ &ReportWriter.write/2) do
    fn path, report ->
      Agent.update(agent, &[{path, report} | &1])
      inner.(path, report)
    end
  end

  defp writes(agent), do: agent |> Agent.get(& &1) |> Enum.reverse()

  # Its own child id: `recorder/0` already owns the plain `Agent` id.
  defp start_writer_agent! do
    start_supervised!(%{
      id: {:writer_agent, System.unique_integer([:positive])},
      start: {Agent, :start_link, [fn -> [] end]}
    })
  end

  defp published!(root) do
    root |> Boot.report_path() |> File.read!() |> Jason.decode!()
  end

  defp fixture(name) do
    @fixture_dir |> Path.join(name) |> File.read!() |> Jason.decode!()
  end

  # Placeholder substitution over any decoded term: the fixtures carry
  # `<pane_a>`, `/synthetic/inbox`, `<tmux_bin>`, `<socket_name>` and the
  # default deadline where a run carries its own values.
  defp substitute(term, subs) when is_list(term), do: Enum.map(term, &substitute(&1, subs))

  defp substitute(term, subs) when is_map(term),
    do: Map.new(term, fn {k, v} -> {substitute(k, subs), substitute(v, subs)} end)

  defp substitute(term, subs), do: Map.get(subs, term, term)

  # ===== rows =====

  describe "READY-ON-RETURN (B3)" do
    test "the report is published before start_link returns; status carries all three outcomes" do
      start_coordinator()
      root = private_root!()
      pane = pane_id()
      own_pane(pane)
      rows = [record(pane, root)]
      census = [observation(pane, "$3", root)]

      store = start_store(lists: [{:ok, rows}, {:ok, rows}])

      tmux =
        start_tmux(
          observe: [{:ok, census}, {:ok, census}],
          show: %{"$3" => [shown(marker_json(root)), shown(marker_json(root))]}
        )

      {agent, callbacks} = recorder()

      boot = start_boot!(boot_opts(store, tmux, callbacks, root))

      # READY-ON-RETURN: the file is already there, with no waiting of any kind.
      path = Boot.report_path(root)
      assert File.regular?(path), "start_link returned before the report was published"

      status = Boot.status(boot)
      assert status.report_write == :ok
      assert {:completed, worker} = status.reconciliation
      refute Process.alive?(worker), "the reconciliation worker must be joined, not abandoned"

      assert [entry] = status.report.panes
      assert entry.pane_id == pane
      assert entry.status == :observed_quarantined
      assert entry.refusals == []
      assert entry.undischarged == @prerequisites
      assert entry.dispatchable == false
      assert status.report.issues == []
      assert status.report.root == root
      assert status.report.marker_writes == 0

      assert status.report.marker_observation ==
               {:observed, %{"$3" => {:observed, marker("$3", root)}}}

      # The bytes on disk are the published report, in the contract's shape.
      published = published!(root)
      assert :ok = BootReportShape.assert_closed_shape!(published)

      assert published ==
               status.report |> BootReportShape.encode() |> BootReportShape.json_round_trip()

      # Compact with exactly one trailing newline, as the contract's fixtures are.
      bytes = File.read!(path)
      assert String.ends_with?(bytes, "\n")
      assert length(String.split(bytes, "\n")) == 2

      # The child is the one every caller finds, and it is quarantined.
      assert {:ok, sm} = PaneSupervisor.whereis_pane(pane)
      assert StateMachine.status(sm).quarantined == true
      assert {:error, :pane_quarantined} = StateMachine.send_text(sm, "hello")
      assert recorded(agent).pastes == []

      # Snapshot read, then exactly one fenced re-read; no write, or the fake is dead.
      assert FakeStore.calls(store) == [:list, :list]
      assert Process.alive?(store)
    end
  end

  describe "every refused row reaches the published report with its own finding" do
    test "B4/B6/B14: an absent marker, a pane absent from the census and a marker naming another session" do
      root = private_root!()
      absent = pane_id()
      dead = pane_id()
      mismatched = pane_id()
      for pane <- [absent, dead, mismatched], do: own_pane(pane)

      rows = [record(absent, root), record(dead, root), record(mismatched, root)]

      census = [
        observation(absent, "$4", root),
        observation(mismatched, "$6", root)
      ]

      store = start_store(lists: [{:ok, rows}])

      tmux =
        start_tmux(
          observe: [{:ok, census}],
          show: %{
            "$4" => [@absent],
            "$6" => [shown(marker_json(root, %{"session_id" => "$2"}))]
          }
        )

      {_agent, callbacks} = recorder()

      boot = start_boot!(boot_opts(store, tmux, callbacks, root))
      status = Boot.status(boot)
      assert status.report_write == :ok

      assert [
               %{pane_id: ^absent, status: :refused, refusals: [{:marker_absent}]},
               %{
                 pane_id: ^dead,
                 status: :refused,
                 refusals: [{:live_absent}, {:source_unavailable, :marker}]
               },
               %{pane_id: ^mismatched, status: :refused, refusals: mismatch_refusals}
             ] = status.report.panes

      assert {:session_mismatch} in mismatch_refusals
      refute {:live_absent} in mismatch_refusals

      published = published!(root)
      assert :ok = BootReportShape.assert_closed_shape!(published)
      by_pane = Map.new(published["panes"], &{&1["pane_id"], &1})
      assert by_pane[absent]["refusals"] == [["marker_absent"]]
      assert by_pane[dead]["refusals"] == [["live_absent"], ["source_unavailable", "marker"]]
      # B14's discrimination: the session mismatch, never live absence.
      assert ["session_mismatch"] in by_pane[mismatched]["refusals"]
      refute ["live_absent"] in by_pane[mismatched]["refusals"]
      assert Enum.all?(published["panes"], &(&1["status"] == "refused"))

      for pane <- [absent, dead, mismatched],
          do: assert(:error = PaneSupervisor.whereis_pane(pane))

      # Retained: one read, no write, the fake alive.
      assert FakeStore.calls(store) == [:list]
      assert Process.alive?(store)
    end

    for {field, label} <- [{"project", "B8a"}, {"project_dir", "B8b"}] do
      test "#{label}: a record whose #{field} differs from the binding is scope_mismatch with the field as text" do
        field = unquote(field)
        root = private_root!()
        pane = pane_id()
        own_pane(pane)

        store = start_store(lists: [{:ok, [record(pane, root, %{field => "/synthetic/other"})]}])

        tmux =
          start_tmux(
            observe: [{:ok, [observation(pane, "$3", root)]}],
            show: %{"$3" => [shown(marker_json(root))]}
          )

        {_agent, callbacks} = recorder()

        boot = start_boot!(boot_opts(store, tmux, callbacks, root))
        status = Boot.status(boot)

        assert [%{pane_id: ^pane, status: :refused, refusals: [{:scope_mismatch, ^field}]}] =
                 status.report.panes

        published = published!(root)

        assert published["panes"] == [
                 %{
                   "dispatchable" => false,
                   "pane_id" => pane,
                   "refusals" => [["scope_mismatch", field]],
                   "status" => "refused",
                   "undischarged" => Enum.map(@prerequisites, &Atom.to_string/1)
                 }
               ]

        assert published["issues"] == [["scope_mismatch", pane, field]]
        assert :error = PaneSupervisor.whereis_pane(pane)
      end
    end

    test "B7: intent withdrawn between the snapshot and the fenced re-read refuses for the INTENT source" do
      start_coordinator()
      root = private_root!()
      pane = pane_id()
      own_pane(pane)
      census = [observation(pane, "$3", root)]

      store = start_store(lists: [{:ok, [record(pane, root)]}, {:ok, []}])

      tmux =
        start_tmux(
          observe: [{:ok, census}, {:ok, census}],
          show: %{"$3" => [shown(marker_json(root)), shown(marker_json(root))]}
        )

      {_agent, callbacks} = recorder()

      boot = start_boot!(boot_opts(store, tmux, callbacks, root))
      status = Boot.status(boot)

      assert [%{pane_id: ^pane, status: :refused, refusals: [{:source_changed, :intent}]}] =
               status.report.panes

      assert published!(root)["panes"] == [
               %{
                 "dispatchable" => false,
                 "pane_id" => pane,
                 "refusals" => [["source_changed", "intent"]],
                 "status" => "refused",
                 "undischarged" => Enum.map(@prerequisites, &Atom.to_string/1)
               }
             ]

      assert :error = PaneSupervisor.whereis_pane(pane)
      assert FakeStore.calls(store) == [:list, :list]
      assert Process.alive?(store)
    end

    test "B13 (reconciliation half): a pane whose fence is held is fence_refused pane_busy and starts no child" do
      start_coordinator()
      root = private_root!()
      pane = pane_id()
      own_pane(pane)
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

      on_exit(fn -> if Process.alive?(holder), do: Process.exit(holder, :kill) end)
      assert_receive {:fence_held, ^pane}, 1_000

      store = start_store(lists: [{:ok, [record(pane, root)]}])

      tmux =
        start_tmux(
          observe: [{:ok, [observation(pane, "$3", root)]}],
          show: %{"$3" => [shown(marker_json(root))]}
        )

      {agent, callbacks} = recorder()

      boot = start_boot!(boot_opts(store, tmux, callbacks, root))
      status = Boot.status(boot)

      assert [%{pane_id: ^pane, status: :refused, refusals: [{:fence_refused, :pane_busy}]}] =
               status.report.panes

      # An execution refusal is never an Admission finding or a report issue.
      assert status.report.issues == []
      assert published!(root)["issues"] == []

      assert published!(root)["panes"] |> hd() |> Map.fetch!("refusals") == [
               ["fence_refused", "pane_busy"]
             ]

      assert :error = PaneSupervisor.whereis_pane(pane)
      assert recorded(agent) == %{captures: [], pastes: []}
      assert FakeStore.calls(store) == [:list]
      assert Process.alive?(store)
    end

    test "B9/B10: a failed marker read and a dead census reach the report and are never collapsed" do
      root = private_root!()
      {_agent, callbacks} = recorder()

      # B9: empty intent, a session whose show-options failed, named by EXACT id.
      orphan = pane_id()
      failed = {:error, %{cmd: ["tmux", "show-options"], status: 3, stderr: "<detail>"}}
      store = start_store(lists: [{:ok, []}])

      tmux =
        start_tmux(observe: [{:ok, [observation(orphan, "$5", root)]}], show: %{"$5" => [failed]})

      boot = start_boot!(boot_opts(store, tmux, callbacks, root))
      status = Boot.status(boot)

      assert status.report.panes == []

      assert [{:session_issue, :marker, "$5", {:source_error, :marker, %{status: 3}}}] =
               status.report.issues

      published = published!(root)
      assert published["panes"] == []

      assert [["session_issue", "marker", "$5", ["source_error", "marker", _]]] =
               published["issues"]

      refute Enum.any?(published["issues"], &match?(["session_issue", "marker", "$50", _], &1))
      assert ["observed", %{"$5" => ["error", %{"status" => 3}]}] = published["marker_observation"]

      # B10: a census adapter that is not there at all.
      dead_root = private_root!()
      dead_store = start_store(lists: [{:ok, []}])

      dead_boot =
        start_boot!(boot_opts(dead_store, :boot_test_no_such_adapter, callbacks, dead_root))

      dead_status = Boot.status(dead_boot)

      assert dead_status.report.panes == []
      assert dead_status.report.issues == [{:source_unavailable, :live}]
      assert dead_status.report.marker_observation == :unobserved

      dead_published = published!(dead_root)
      assert dead_published["issues"] == [["source_unavailable", "live"]]
      assert dead_published["marker_observation"] == "unobserved"
      assert :ok = BootReportShape.assert_closed_shape!(dead_published)
    end
  end

  describe "the report writer boundary (B11)" do
    test "B11: the injected function is handed the report path and the published report; its failure is surfaced, logged, never fatal" do
      start_coordinator()
      root = private_root!()
      pane = pane_id()
      own_pane(pane)
      rows = [record(pane, root)]
      census = [observation(pane, "$3", root)]

      store = start_store(lists: [{:ok, rows}, {:ok, rows}])

      tmux =
        start_tmux(
          observe: [{:ok, census}, {:ok, census}],
          show: %{"$3" => [shown(marker_json(root)), shown(marker_json(root))]}
        )

      {_agent, callbacks} = recorder()
      me = self()

      writer = fn path, report ->
        send(me, {:report_writer_called, path, report})
        {:error, :induced_write_failure}
      end

      {boot, log} =
        with_log(fn ->
          start_boot!(boot_opts(store, tmux, callbacks, root, report_writer: writer))
        end)

      status = Boot.status(boot)

      assert_receive {:report_writer_called, written_path, written_report}, 1_000
      assert written_path == Path.join([root, "state", "boot-report.json"])
      assert written_path == Boot.report_path(root)
      assert written_report == status.report, "the writer must be handed the published report"

      assert status.report_write == {:error, :induced_write_failure}
      assert log =~ "induced_write_failure", "the report-write failure must be logged"

      # Not fatal: the child is alive, still answering, and the report is intact.
      assert Process.alive?(boot)
      assert [%{status: :observed_quarantined}] = status.report.panes

      # The failing writer published nothing: no file, and the injected writer
      # replaces the production one entirely.
      refute File.exists?(Boot.report_path(root))
    end

    test "a behaviour module exporting write/2 is accepted at the same boundary" do
      root = private_root!()
      pane = pane_id()
      own_pane(pane)

      start_supervised!(%{
        id: ModuleWriter,
        start: {Agent, :start_link, [fn -> [] end, [name: ModuleWriter]]}
      })

      store = start_store(lists: [{:ok, [record(pane, root)]}])

      tmux =
        start_tmux(
          observe: [{:ok, [observation(pane, "$4", root)]}],
          show: %{"$4" => [@absent]}
        )

      {_agent, callbacks} = recorder()

      boot = start_boot!(boot_opts(store, tmux, callbacks, root, report_writer: ModuleWriter))
      status = Boot.status(boot)

      assert status.report_write == :ok
      assert [{path, report}] = ModuleWriter.calls()
      assert path == Boot.report_path(root)
      assert report == status.report
      refute File.exists?(path)
    end

    test "a writer that raises, exits or answers an unknown term is an error disposition, never fatal" do
      root = private_root!()
      {_agent, callbacks} = recorder()

      cases = [
        {fn _path, _report -> raise "sink is on fire" end, :raise},
        {fn _path, _report -> exit(:sink_gone) end, :exit},
        {fn _path, _report -> :written end, :invalid}
      ]

      for {writer, kind} <- cases do
        store = start_store(lists: [{:ok, []}])
        tmux = start_tmux(observe: [{:ok, []}])

        {boot, _log} =
          with_log(fn ->
            start_boot!(boot_opts(store, tmux, callbacks, root, report_writer: writer))
          end)

        status = Boot.status(boot)
        assert Process.alive?(boot), "a sink failure (#{kind}) must never be fatal to the boot"
        assert status.report.panes == []
        assert status.report.marker_observation == :not_applicable

        case kind do
          :raise ->
            assert {:error, {:report_writer_failed, :error, %RuntimeError{}}} = status.report_write

          :exit ->
            assert {:error, {:report_writer_failed, :exit, :sink_gone}} = status.report_write

          :invalid ->
            assert status.report_write == {:error, {:invalid_writer_result, :written}}
        end
      end
    end

    test "a production write failure is a disposition: the report is intact and Boot still answers" do
      root = private_root!()
      # The state path is occupied by a regular file, so mkdir_p cannot make the
      # directory and the publish fails at its first step.
      File.write!(Path.join(root, "state"), "not a directory")

      store = start_store(lists: [{:ok, []}])
      tmux = start_tmux(observe: [{:ok, []}])
      {_agent, callbacks} = recorder()

      {boot, log} = with_log(fn -> start_boot!(boot_opts(store, tmux, callbacks, root)) end)
      status = Boot.status(boot)

      assert {:error, reason} = status.report_write
      assert reason in [:eexist, :enotdir, :eisdir], "unexpected write failure: #{inspect(reason)}"
      assert log =~ "boot report write failed"
      assert Process.alive?(boot)
      assert status.report.root == root
      assert status.report.panes == []
      # Nothing half-published: the occupied path still holds exactly its bytes.
      assert File.read!(Path.join(root, "state")) == "not a directory"
    end
  end

  describe "atomic publication" do
    test "the temporary path is in the target directory, hidden, and not a *.json name" do
      target = Boot.report_path("/synthetic/inbox")
      temp = ReportWriter.temp_path(target)

      refute temp == target
      assert Path.dirname(temp) == Path.dirname(target), "rename must not cross a filesystem"
      assert String.starts_with?(Path.basename(temp), ".")
      assert String.ends_with?(temp, ".tmp")
      refute String.ends_with?(temp, ".json")
      refute ReportWriter.temp_path(target) == temp, "each publish needs its own temporary name"
    end

    test "the target is replaced by rename, never written in place: an open reader keeps the whole old document" do
      root = private_root!()
      path = Boot.report_path(root)
      {_agent, callbacks} = recorder()

      # First publication: an empty report.
      first_store = start_store(lists: [{:ok, []}])
      first_tmux = start_tmux(observe: [{:ok, []}])
      start_boot!(boot_opts(first_store, first_tmux, callbacks, root))

      first_bytes = File.read!(path)
      {:ok, before_stat} = File.stat(path)
      {:ok, reader} = File.open(path, [:read, :binary])

      # Second publication over the SAME target: a refused pane, so the bytes differ.
      pane = pane_id()
      own_pane(pane)
      second_store = start_store(lists: [{:ok, [record(pane, root)]}])

      second_tmux =
        start_tmux(observe: [{:ok, [observation(pane, "$4", root)]}], show: %{"$4" => [@absent]})

      boot = start_boot!(boot_opts(second_store, second_tmux, callbacks, root))
      assert Boot.status(boot).report_write == :ok

      second_bytes = File.read!(path)
      {:ok, after_stat} = File.stat(path)

      refute second_bytes == first_bytes
      assert {:ok, _} = Jason.decode(second_bytes)

      # A plain in-place write keeps the inode and truncates what the open
      # reader sees; a temp-file publish replaces the name.
      refute after_stat.inode == before_stat.inode,
             "the target was written in place, not renamed onto"

      assert IO.binread(reader, :eof) == first_bytes,
             "a reader that opened the report before the publish saw a partial document"

      :ok = File.close(reader)

      # Nothing is left behind: the state directory holds the report alone.
      assert File.ls!(Path.dirname(path)) == ["boot-report.json"]
    end
  end

  describe "the deadline (B12a, B12b)" do
    test "B12a: a snapshot read that never answers is terminated and joined at the deadline, and the timed-out report is published" do
      root = private_root!()
      pane = pane_id()
      own_pane(pane)
      rows = [record(pane, root)]

      # The FIRST `:list` is held and never released by this row.
      store = start_store(lists: [{:ok, rows}], hold: 1, notify: self())
      tmux = start_tmux(observe: [{:ok, [observation(pane, "$3", root)]}])
      {_agent, callbacks} = recorder()

      started_at = System.monotonic_time(:millisecond)

      boot =
        start_boot!(boot_opts(store, tmux, callbacks, root, deadline_ms: 200))

      elapsed_ms = System.monotonic_time(:millisecond) - started_at
      status = Boot.status(boot)

      assert_receive {:list_held, 1, ^store, worker}, 3_000
      assert elapsed_ms >= 200, "Boot returned before its 200ms deadline (#{elapsed_ms}ms)"
      assert elapsed_ms < 5_000, "Boot returned #{elapsed_ms}ms after a 200ms deadline"

      assert {:timed_out, %{worker: ^worker, joined: true}} = status.reconciliation
      refute Process.alive?(worker), "the reconciliation worker must be joined, not abandoned"
      assert Process.alive?(boot), "a timed-out boot is still a ready child"

      assert status.report == %{
               root: root,
               panes: [],
               issues: [{:reconciliation_timeout, 200}],
               marker_observation: :unobserved,
               marker_writes: 0
             }

      assert status.report_write == :ok
      published = published!(root)
      assert :ok = BootReportShape.assert_closed_shape!(published)
      assert published["panes"] == []
      assert published["issues"] == [["reconciliation_timeout", 200]]
      assert published["marker_observation"] == "unobserved"

      assert :error = PaneSupervisor.whereis_pane(pane)
      assert Process.alive?(store), "the record must be retained: no write was attempted"
      assert FakeStore.calls(store) == [:list]
    end

    test "B12b: a deadline during the FENCED re-read publishes the timed-out report, starts no child and leaves the pane fenced" do
      start_coordinator()
      root = private_root!()
      pane = pane_id()
      own_pane(pane)
      rows = [record(pane, root)]
      census = [observation(pane, "$3", root)]

      # The SECOND `:list` - the re-read inside the pane's fence - is held.
      store = start_store(lists: [{:ok, rows}, {:ok, rows}], hold: 2, notify: self())

      tmux =
        start_tmux(
          observe: [{:ok, census}, {:ok, census}],
          show: %{"$3" => [shown(marker_json(root)), shown(marker_json(root))]}
        )

      {agent, callbacks} = recorder()
      writer_agent = start_writer_agent!()

      boot =
        start_boot!(
          boot_opts(store, tmux, callbacks, root,
            deadline_ms: 200,
            report_writer: counting_writer(writer_agent)
          )
        )

      assert_receive {:list_held, 2, ^store, worker}, 3_000
      status = Boot.status(boot)

      assert {:timed_out, %{worker: ^worker, joined: true}} = status.reconciliation
      refute Process.alive?(worker)
      assert status.report.issues == [{:reconciliation_timeout, 200}]
      assert status.report.panes == []

      published_bytes = File.read!(Boot.report_path(root))
      assert [{_path, _report}] = writes(writer_agent)

      # No child was started: the deadline struck before the fenced decision.
      assert :error = PaneSupervisor.whereis_pane(pane)
      assert recorded(agent) == %{captures: [], pastes: []}

      # The pane's fence is not silently reopened by the holder's death: the
      # transaction is refused, never admitted on a lost holder's behalf.
      assert {:error, :unresolved_operation} =
               Coordinator.transaction(pane, fn -> {:ok, :never} end)

      # Releasing the held read now is a reply to a process that no longer
      # exists: nothing is republished and the report does not change.
      FakeStore.release(store)
      assert Boot.status(boot).report == status.report
      assert File.read!(Boot.report_path(root)) == published_bytes
      assert length(writes(writer_agent)) == 1
      assert Process.alive?(store)
    end

    test "a published report is never rewritten: a reply-shaped message and a stray message change nothing" do
      start_coordinator()
      root = private_root!()
      pane = pane_id()
      own_pane(pane)
      rows = [record(pane, root)]
      census = [observation(pane, "$3", root)]

      store = start_store(lists: [{:ok, rows}, {:ok, rows}])

      tmux =
        start_tmux(
          observe: [{:ok, census}, {:ok, census}],
          show: %{"$3" => [shown(marker_json(root)), shown(marker_json(root))]}
        )

      {_agent, callbacks} = recorder()
      writer_agent = start_writer_agent!()

      boot =
        start_boot!(
          boot_opts(store, tmux, callbacks, root, report_writer: counting_writer(writer_agent))
        )

      before_status = Boot.status(boot)
      before_bytes = File.read!(Boot.report_path(root))
      assert length(writes(writer_agent)) == 1

      # Exactly the shape a late reconciliation reply has, plus an unrelated
      # message. The status call that follows is ordered behind both.
      forged = %{
        root: "/synthetic/forged",
        panes: [],
        issues: [],
        marker_observation: :unobserved,
        marker_writes: 99
      }

      send(boot, {make_ref(), forged})
      send(boot, :some_other_message)

      assert Boot.status(boot) == before_status
      assert File.read!(Boot.report_path(root)) == before_bytes
      assert length(writes(writer_agent)) == 1

      # Post-boot lifecycle work on the same pane changes process state, never
      # the file (the contract's "Late coordinator effects change process state,
      # never the file").
      assert {:ok, :later} = Coordinator.transaction(pane, fn -> {:ok, :later} end)
      assert :ok = PaneSupervisor.stop_pane(pane)
      assert Boot.status(boot) == before_status
      assert File.read!(Boot.report_path(root)) == before_bytes
      assert length(writes(writer_agent)) == 1
    end
  end

  describe "caller defects and unexpected failure" do
    test "unknown, missing and invalid options raise in the caller, before any process exists" do
      root = private_root!()
      store = start_store(lists: [])
      tmux = start_tmux(observe: [])
      {_agent, callbacks} = recorder()
      opts = boot_opts(store, tmux, callbacks, root)

      assert_raise ArgumentError, fn -> Boot.start_link(Keyword.put(opts, :extra, 1)) end
      assert_raise ArgumentError, fn -> Boot.start_link(Keyword.delete(opts, :callbacks)) end
      assert_raise ArgumentError, fn -> Boot.start_link(Keyword.delete(opts, :store)) end
      assert_raise ArgumentError, fn -> Boot.start_link(Keyword.put(opts, :root, "relative")) end
      assert_raise ArgumentError, fn -> Boot.start_link(Keyword.put(opts, :deadline_ms, 0)) end
      assert_raise ArgumentError, fn -> Boot.start_link(Keyword.put(opts, :deadline_ms, :soon)) end
      assert_raise ArgumentError, fn -> Boot.start_link(Keyword.put(opts, :report_writer, Enum)) end

      assert_raise ArgumentError, fn ->
        Boot.start_link(Keyword.put(opts, :report_writer, fn _only -> :ok end))
      end

      # Nothing was observed and nothing was published by any of them.
      assert FakeStore.calls(store) == []
      assert FakeTmux.requests(tmux) == []
      refute File.exists?(Boot.report_path(root))
    end

    test "an unexpected reconciliation failure fails startup instead of publishing an empty report" do
      root = private_root!()
      store = start_store(lists: [{:ok, []}])
      # A census reply outside the adapter's contract: the worker dies on it.
      tmux = start_tmux(observe: [:not_a_census_reply])
      {_agent, callbacks} = recorder()

      {result, _log} =
        with_log(fn -> start_supervised(boot_spec(boot_opts(store, tmux, callbacks, root))) end)

      assert {:error, error} = result

      assert match?({:reconciliation_failed, _}, error) or
               match?({{:reconciliation_failed, _}, _}, error),
             "a crashed worker must fail startup, got: #{inspect(error)}"

      refute File.exists?(Boot.report_path(root)),
             "a crash must never be published as a successful empty report"
    end
  end

  describe "the frozen fixtures are reproduced through the production writer" do
    test "boot-report.clean.json, published by Boot through the real tmux adapter" do
      start_coordinator()
      root = private_root!()
      pane = pane_id()
      own_pane(pane)
      rows = [record(pane, root)]
      census = {census_row(pane, "$3", root), 0}
      shown_marker = {marker_json(root) <> "\n", 0}

      {tmux, _dir} = ScriptedTmux.start!([census, shown_marker, census, shown_marker])
      store = start_store(lists: [{:ok, rows}, {:ok, rows}])
      {_agent, callbacks} = recorder()

      boot = start_boot!(boot_opts(store, tmux, callbacks, root))
      assert Boot.status(boot).report_write == :ok

      published = published!(root)
      assert :ok = BootReportShape.assert_closed_shape!(published)

      assert substitute(published, %{pane => "<pane_id>", root => @fixture_root}) ==
               fixture("boot-report.clean.json")

      bytes = File.read!(Boot.report_path(root))
      assert String.ends_with?(bytes, "\n")
      assert length(String.split(bytes, "\n")) == 2, "the document must be compact"
      assert Process.alive?(store)
    end

    test "boot-report.deadline_expired.json, up to the root and the deadline" do
      root = private_root!()
      store = start_store(lists: [{:ok, []}], hold: 1, notify: self())
      tmux = start_tmux(observe: [{:ok, []}])
      {_agent, callbacks} = recorder()

      boot = start_boot!(boot_opts(store, tmux, callbacks, root, deadline_ms: 200))
      assert Boot.status(boot).report_write == :ok
      assert_receive {:list_held, 1, ^store, _worker}, 3_000

      published = published!(root)
      assert :ok = BootReportShape.assert_closed_shape!(published)

      # The fixture pins the DEFAULT 10_000 ms deadline; this row uses 200 ms so
      # the suite does not sleep for ten seconds, and substitutes it like any
      # other placeholder.
      assert substitute(published, %{root => @fixture_root, 200 => 10_000}) ==
               fixture("boot-report.deadline_expired.json")
    end

    test "boot-report.refusals_and_issues.json: six rows, five refusals and a session issue" do
      start_coordinator()
      root = private_root!()
      [a, b, c, d, e, f, orphan] = for _ <- 1..7, do: pane_id()
      for pane <- [a, b, c, d, e, f], do: own_pane(pane)
      test = self()

      holder =
        spawn(fn ->
          Coordinator.transaction(e, fn ->
            send(test, {:fence_held, e})

            receive do
              :release -> {:ok, :released}
            end
          end)
        end)

      on_exit(fn -> if Process.alive?(holder), do: Process.exit(holder, :kill) end)
      assert_receive {:fence_held, ^e}, 1_000

      rows = [
        record(a, root),
        record(b, root),
        record(c, root),
        record(d, root, %{"project" => "other-project"}),
        record(e, root),
        record(f, root)
      ]

      # c is not in the census; the orphan in $5 has no record; sessions are
      # enumerated in census order: $3, $4, $6, $5.
      census_output =
        census_row(a, "$3", root) <>
          census_row(b, "$4", root) <>
          census_row(d, "$3", root) <>
          census_row(e, "$3", root) <>
          census_row(f, "$6", root) <> census_row(orphan, "$5", root)

      census = {census_output, 0}
      marker_3 = {marker_json(root) <> "\n", 0}
      marker_4_absent = {"invalid option: #{@option}\n", 1, :stderr}
      marker_6_names_2 = {marker_json(root, %{"session_id" => "$2"}) <> "\n", 0}
      marker_5_failed = {"<detail>", 3, :stderr}

      {tmux, dir} =
        ScriptedTmux.start!(
          [census, marker_3, marker_4_absent, marker_6_names_2, marker_5_failed, census, marker_3],
          socket_name: "fixture_sock"
        )

      store = start_store(lists: [{:ok, rows}, {:ok, rows}])
      {_agent, callbacks} = recorder()

      boot = start_boot!(boot_opts(store, tmux, callbacks, root))
      assert Boot.status(boot).report_write == :ok

      published = published!(root)
      assert :ok = BootReportShape.assert_closed_shape!(published)

      subs = %{
        a => "<pane_a>",
        b => "<pane_b>",
        c => "<pane_c>",
        d => "<pane_d>",
        e => "<pane_e>",
        f => "<pane_f>",
        root => @fixture_root,
        Path.join(dir, "tmux") => "<tmux_bin>",
        "fixture_sock" => "<socket_name>"
      }

      assert substitute(published, subs) == fixture("boot-report.refusals_and_issues.json")

      # Exactly one child: a. Every other record retained, no write.
      assert {:ok, _} = PaneSupervisor.whereis_pane(a)
      for pane <- [b, c, d, e, f, orphan], do: assert(:error = PaneSupervisor.whereis_pane(pane))
      assert FakeStore.calls(store) == [:list, :list]
      assert Process.alive?(store)
      assert ScriptedTmux.calls!(dir) == 7
    end
  end
end
