defmodule AiPair.PaneRestore.BootWiringTest do
  # R04 slice S11: the reviewed lane RED
  # `test/ai_pair/pane_restore/boot_wiring_test.exs` at
  # `56b5c7b500a9c1f51b0ff8b5afce70c966142e24`, replayed ONTO Orrisd main with
  # S1-S8 merged. Only the rows main can satisfy today are carried; the rows
  # whose product behaviour belongs to S9 (IPC durable attach/detach) or S10
  # (the Application durable branch), and the rows whose fixture starts a LIVE
  # tmux server, are classified in R04-S11-RECORD.org and are deliberately NOT
  # reproduced here as fakes: a row whose fixture cannot be built truthfully is
  # listed, never weakened into a green assertion.
  #
  # What is here:
  #   * the default-route boundary rows (new for this slice): the guarantee
  #     `AiPair.Test.RouteGuard` exists to make, proven over EVERY call shape
  #     main's adapter serves, with a fixture-owned adapter as the refutation
  #     control so the refusal cannot be mistaken for an impossible call;
  #   * CC1-CC25, the lane's containment controls, verbatim except for the
  #     module names of the three support modules that now live under
  #     `test/support`; they gate the fixture's own safety and travel with the
  #     guard;
  #   * B1 (the legacy Application tree) measured IN PLACE against the running
  #     application rather than through the lane's full-application restart
  #     harness, which belongs to S10 (see the record for what that costs);
  #   * T2 (the attach trace carrier), which main satisfies by source and which
  #     no suite on main measured before this slice.
  use ExUnit.Case, async: false

  import AiPair.Test.OtelHelper

  alias AiPair.CLI.Client
  alias AiPair.PaneIntentStore
  alias AiPair.Test.ContainmentCollector
  alias AiPair.Test.Escape
  alias AiPair.Test.RouteGuard
  alias AiPair.Test.TerminationWitness
  alias AiPair.Tmux

  # =========================================================================
  # THE DEFAULT-ROUTE BOUNDARY (new for S11)
  #
  # `AiPair.Test.RouteGuard` claims that holding the `AiPair.Tmux` registered
  # name refuses every default route before any external command can exist.
  # These rows measure that claim rather than assume it. The refusal is a
  # catch-all clause, so the assertion is over the WHOLE set of calls the real
  # adapter answers, derived from the adapter's own `handle_call/3` clauses, not
  # from a list this file maintains.
  # =========================================================================

  # Every request term `AiPair.Tmux.handle_call/3` answers, each paired with the
  # public entry point that builds it. Both halves are asserted below: the
  # public function returns the refusal map, AND the guard records the op. A
  # private function rather than a module attribute, because an anonymous
  # function cannot be stored in one.
  defp adapter_calls do
    [
      {:list_panes, fn -> Tmux.list_panes() end},
      {:observe_panes, fn -> Tmux.observe_panes() end},
      {:capture_pane, fn -> Tmux.capture_pane("%boundary") end},
      {:send_keys, fn -> Tmux.send_keys("%boundary", ["Enter"]) end},
      {:set_buffer, fn -> Tmux.set_buffer("ai_pair_boundary", "payload") end},
      {:paste_buffer, fn -> Tmux.paste_buffer("%boundary", "ai_pair_boundary") end},
      {:delete_buffer, fn -> Tmux.delete_buffer("ai_pair_boundary") end},
      {:display_message, fn -> Tmux.display_message("%boundary", "msg") end},
      {:show_options, fn -> Tmux.show_options("$boundary", "@opt") end},
      {:set_option, fn -> Tmux.set_option("$boundary", "@opt", "v") end},
      {:set_option_if_absent, fn -> Tmux.set_option_if_absent("$boundary", "@opt", "v") end}
    ]
  end

  describe "the default-route boundary" do
    test "the guard, not the application's adapter, holds the registered name" do
      app_adapter = Process.whereis(AiPair.Tmux)
      assert is_pid(app_adapter), "the application's tmux adapter must be running before install"

      guard = RouteGuard.install!()

      assert Process.whereis(AiPair.Tmux) == guard
      refute guard == app_adapter
      refute Process.alive?(app_adapter), "install! must terminate the application's own child"
    end

    test "EVERY call the adapter serves is refused with the documented error shape and recorded" do
      guard = RouteGuard.install!()

      for {op, invoke} <- adapter_calls() do
        assert {:error, %{cmd: ["FORBIDDEN-DEFAULT-ROUTE", stated], status: -2, stderr: stderr}} =
                 invoke.(),
               "default-routed #{op} was not refused"

        assert stated == Atom.to_string(op)
        assert stderr =~ "test route guard refused"
      end

      recorded = RouteGuard.violations(guard)
      assert Enum.map(recorded, &elem(&1, 0)) == Enum.map(adapter_calls(), &elem(&1, 0))

      assert Enum.all?(recorded, fn {_op, caller} -> caller == self() end),
             "the refusal must record the CALLER, not the guard"
    end

    test "the guarded set is exactly the set the adapter serves: no shape escapes the boundary" do
      # Derived from the product module, so a call added to `AiPair.Tmux`
      # without a matching row here is a FAILURE rather than a silent gap. The
      # adapter's clause heads are read from its debug info; the guard has no
      # per-shape clause at all, so the comparison is between the product and
      # this file, never between the guard and itself.
      guard = RouteGuard.install!()

      covered = adapter_calls() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

      assert covered == Enum.sort(adapter_request_ops()),
             "AiPair.Tmux serves a call shape this boundary row does not exercise"

      # And an op NOBODY enumerated is refused too, because the clause is a
      # catch-all: a future adapter call cannot escape by being unknown here.
      assert {:error, %{cmd: ["FORBIDDEN-DEFAULT-ROUTE", "not_a_real_tmux_call"], status: -2}} =
               GenServer.call(AiPair.Tmux, {:not_a_real_tmux_call, "x"})

      assert {:not_a_real_tmux_call, _} = List.last(RouteGuard.violations(guard))
    end

    test "REFUTATION CONTROL: the same calls succeed through a fixture-owned adapter" do
      # Without this the refusals above could be explained by the calls being
      # impossible in the test environment. They are not: an adapter this row
      # owns, bound to a fixture `tmux` that never execs the real binary,
      # answers every one of them.
      {owned, _dir} = fake_tmux!()
      _guard = RouteGuard.install!()

      assert {:ok, []} = Tmux.list_panes(owned)
      assert {:ok, []} = Tmux.observe_panes(owned)
      assert {:ok, ""} = Tmux.show_options("$fixture", "@opt", owned)
      assert :ok = Tmux.set_option("$fixture", "@opt", "v", owned)
      assert :ok = Tmux.set_option_if_absent("$fixture", "@opt", "v", owned)
      assert :ok = Tmux.send_keys("%fixture", ["Enter"], owned)

      # The default route is refused in the SAME row, so the discriminator is
      # the target, not the environment.
      assert {:error, %{status: -2}} = Tmux.list_panes()
    end

    test "a pane started the product way routes its capture into the boundary, not the operator's tmux" do
      # The defect class the guard exists for: `IPC.Server.attach_pane/3`
      # supplies NO callbacks, so `StateMachine` uses `default_capture/1`, which
      # addresses the registered name. Under the guard that capture is refused
      # and RECORDED; without the guard it would execute `tmux` with no `-L`
      # against the operator's own server.
      guard = RouteGuard.install!()
      pane_id = synthetic_pane_id()
      :ok = RouteGuard.own_pane(guard, pane_id)

      assert {:ok, child} = AiPair.PaneSupervisor.start_pane(pane_id, [])
      assert Process.alive?(child)

      assert %{state: state} = AiPair.Pane.StateMachine.status(child)
      assert state in [:idle, :busy, :dialog, :dead, :unknown]

      captures = fn ->
        for {:capture_pane, caller} <- RouteGuard.violations(guard), do: caller
      end

      wait_until!(
        fn -> child in captures.() end,
        System.monotonic_time(:millisecond) + 2_000,
        "the pane child's default capture reaches the boundary"
      )

      assert child in captures.(),
             "the pane child's default capture did not reach the boundary: #{inspect(RouteGuard.violations(guard))}"
    end

    test "restoration returns the application's own adapter, and only after containment" do
      guard = RouteGuard.install!(register_teardown: false)
      owner = RouteGuard.owner_of(guard)
      on_exit(fn -> if Process.alive?(owner), do: RouteGuard.restore!(owner) end)

      assert Process.whereis(AiPair.Tmux) == guard
      assert :ok = RouteGuard.contain!(owner)
      RouteGuard.restore!(owner)

      restored = Process.whereis(AiPair.Tmux)
      assert is_pid(restored)
      refute restored == guard
      refute Process.alive?(guard), "the rejector must be gone once routing is real again"
    end
  end

  # =========================================================================
  # B1, measured in place (the full-application restart harness is S10's)
  # =========================================================================

  # The eight children a legacy boot starts, in `which_children` order.
  @legacy_child_ids [
    AiPair.IPC.Server,
    AiPair.Delivery.ReceiptStore,
    AiPair.IPC.ConnectionSupervisor,
    AiPair.Tmux,
    AiPair.Inbox.StuckScanner,
    AiPair.PaneSupervisor,
    AiPair.Telemetry.OtelBridge,
    AiPair.Registry
  ]

  describe "application boot (B1, in place)" do
    test "B1 the running legacy tree is exactly the eight children, with no store, Boot or Coordinator" do
      inbox = Application.fetch_env!(:ai_pair, :inbox)

      refute Application.get_env(:ai_pair, :durable_attachments) == true,
             "this row measures the LEGACY branch; durable_attachments must not be enabled"

      assert child_ids() == @legacy_child_ids, "legacy boot child list changed"

      assert :undefined == :global.whereis_name({PaneIntentStore, Path.expand(inbox)}),
             "legacy boot must not start the pane-intent store"

      assert Process.whereis(AiPair.PaneRestore.Boot) == nil, "legacy boot must not start Boot"

      assert Process.whereis(AiPair.PaneRestore.Coordinator) == nil,
             "legacy boot must not start the Coordinator"

      refute File.exists?(Path.join([inbox, "state", "boot-report.json"])),
             "legacy boot must not write a boot report"
    end
  end

  # =========================================================================
  # T2 (trace propagation over the attach frame)
  # =========================================================================

  describe "trace propagation" do
    test "T2 attach inside a cli.attach span: ipc.attach_pane parents to cli.attach" do
      inbox = inbox_root!()
      _guard = RouteGuard.install!()
      setup_otel_capture()

      prior_sock = System.get_env("AI_PAIR_DAEMON_SOCK")
      sock_path = Path.join(inbox, "sock/ai-pair.sock")
      System.put_env("AI_PAIR_DAEMON_SOCK", sock_path)

      on_exit(fn ->
        case prior_sock do
          nil -> System.delete_env("AI_PAIR_DAEMON_SOCK")
          v -> System.put_env("AI_PAIR_DAEMON_SOCK", v)
        end
      end)

      {:ok, _ipc} = ipc_server!(inbox, :ipc_s11_t2)

      pane_id = synthetic_pane_id()
      :ok = RouteGuard.own_pane(pane_id)
      flush_spans()

      _out =
        ExUnit.CaptureIO.capture_io(fn ->
          send(self(), {:exit, Client.main(["attach", pane_id])})
        end)

      assert {:ok, cli_span} = assert_span([name: "cli.attach"], 1_000)
      assert {:ok, ipc_span} = assert_span([name: "ipc.attach_pane"], 1_000)

      assert parent_span_id(ipc_span) == span_id(cli_span),
             "ipc.attach_pane must be a child of cli.attach (traceparent over UDS)"
    end
  end

  # =========================================================================
  # CONTAINMENT CONTROLS (m_1789247933 point 6; F1-F6 of m_1789249509; B1-B5 of
  # m_1789250979): the collector and the guard's collector-first path are
  # exercised through the SAME contain!/1 and restore!/1 that install!/1
  # registers, against the inert effects recorder, so a guard that ignored a
  # collector's verdict, a collector that inferred a child's death from its
  # parent's, a one-shot snapshot, a drain that outlived the shared deadline,
  # or a restoration decided from a stale read FAILS here. Every fixture
  # process is created with plain `spawn` by its real parent - no link to the
  # test, no registered name - so link- or name-based cleanup could not pass
  # them; only spawn provenance can. Each row registers its Escape cleanup
  # BEFORE any acquisition and reserves EVERY creation before it happens (B4),
  # so a row that fails before its first pid report still joins everything it
  # created and its inert boundary, and an unknown creation is reported as
  # unresolved rather than cleared. These rows do not touch the product Boot or
  # coordinator and are measurable before GREEN.
  #
  # Group label: ExUnit compiles each row to a function named
  # "test <describe> <name>" and the compiler derives anonymous-function atoms
  # from it; the former long describe ("... provenance, fixed point, deadline,
  # finalization and cleanup") pushed CC15's derived atom past the atom size
  # limit (SystemLimitError before any body ran, measured at 533d28f). The
  # parser classifies controls by the "CONTAINMENT CONTROLS" prefix, so the
  # label is that prefix alone and every compiled name stays under 200 bytes.
  # =========================================================================
  describe "CONTAINMENT CONTROLS" do
    test "CC1 success: root, child and grandchild are discovered by provenance, joined and flushed; session destroyed; collector joined; restoration proceeds" do
      %{owner: owner, name: name, log: log, collector: collector, escape: escape} =
        control_boundary!()

      root = chain_root!(collector, escape)
      assert_receive {:chain, :child, child}, 2_000
      assert_receive {:chain, :grandchild, grandchild}, 2_000
      assert Enum.all?([root, child, grandchild], &Process.alive?/1)

      # The point: nothing here is linked or named; only the collector can reach
      # child and grandchild, and only through the spawn events.
      assert :ok = RouteGuard.contain!(owner)

      refute Process.alive?(root)
      refute Process.alive?(child), "the child was not joined: provenance did not reach it"

      refute Process.alive?(grandchild),
             "the grandchild was not joined: set_on_spawn provenance did not reach it"

      refute Process.alive?(collector),
             "the guard must stop and join the collector before restoration"

      RouteGuard.restore!(owner)
      assert [{:terminate, ^name}, {:restart, ^name}] = effects_log(log)
    end

    test "CC2 an ARMED root dead before containment: its orphaned child and grandchild are still discovered and joined" do
      %{owner: owner, name: name, log: log, collector: collector, escape: escape} =
        control_boundary!()

      root = chain_root!(collector, escape)
      assert_receive {:chain, :child, child}, 2_000
      assert_receive {:chain, :grandchild, grandchild}, 2_000

      root_ref = Process.monitor(root)
      Process.exit(root, :kill)
      assert_receive {:DOWN, ^root_ref, :process, ^root, :killed}, 2_000
      assert Process.alive?(child) and Process.alive?(grandchild)

      assert :ok = RouteGuard.contain!(owner)

      refute Process.alive?(child), "an orphaned descendant was not joined"
      refute Process.alive?(grandchild), "an orphaned grandchild was not joined"
      refute Process.alive?(collector)

      RouteGuard.restore!(owner)
      assert [{:terminate, ^name}, {:restart, ^name}] = effects_log(log)
    end

    test "CC3 a root that died while PARKED never had creation authority: containment succeeds" do
      %{owner: owner, name: name, log: log, collector: collector, escape: escape} =
        control_boundary!()

      tag = {:root, make_ref()}
      Escape.reserve!(escape, tag)
      {:ok, root} = ContainmentCollector.acquire_root(collector, self(), fn -> :never end)
      Escape.fulfil!(escape, tag, root)
      ref = Process.monitor(root)
      Process.exit(root, :kill)
      assert_receive {:DOWN, ^ref, :process, ^root, :killed}, 2_000
      refute_receive {:chain, _, _}, 200, "a parked root must not have created anything"

      assert :ok = RouteGuard.contain!(owner)
      RouteGuard.restore!(owner)
      assert [{:terminate, ^name}, {:restart, ^name}] = effects_log(log)
    end

    test "CC4 a DEAD collector is unknown provenance: containment fails, the retained rejector keeps refusing, late ownership is refused" do
      %{owner: owner, name: name, log: log, guard: guard, collector: collector, escape: escape} =
        control_boundary!()

      ref = Process.monitor(collector)
      Process.exit(collector, :kill)
      assert_receive {:DOWN, ^ref, :process, ^collector, :killed}, 2_000

      assert_raise RuntimeError, ~r/were not contained.*provenance is UNKNOWN/s, fn ->
        RouteGuard.contain!(owner)
      end

      assert_raise RuntimeError, ~r/containment unresolved/, fn -> RouteGuard.restore!(owner) end

      refute Enum.any?(effects_log(log), &match?({:restart, _}, &1)),
             "real routing must NOT be restored when producer provenance is unknown"

      # F4: the boundary survives its failed restoration WITH its registry.
      late = escape_spawn!(escape)
      assert {:error, :containment_failed} = RouteGuard.own_process(guard, late)
      assert Process.whereis(name) == guard, "the rejecting boundary stays up on failure"
      violations_before = length(RouteGuard.violations(guard))

      assert {:error, %{cmd: ["FORBIDDEN-DEFAULT-ROUTE", "list_panes"]}} =
               GenServer.call(name, :list_panes)

      assert length(RouteGuard.violations(guard)) == violations_before + 1

      assert Process.alive?(late),
             "the refused late process must not have been touched by the guard"
    end

    test "CC5 a collector answering a controlled error: containment fails, the collector is left alone, restoration is withheld, refusal continues" do
      %{owner: owner, name: name, log: log, guard: guard, collector: collector, escape: escape} =
        control_boundary!(collector_opts: [contain_override: {:error, {:unjoined, :controlled}}])

      assert_raise RuntimeError, ~r/were not contained.*producer containment failed/s, fn ->
        RouteGuard.contain!(owner)
      end

      assert Process.alive?(collector)
      assert ContainmentCollector.phase(collector) == :failed

      assert_raise RuntimeError, ~r/containment unresolved/, fn -> RouteGuard.restore!(owner) end

      refute Enum.any?(effects_log(log), &match?({:restart, _}, &1)),
             "real routing must NOT be restored on a collector error"

      late = escape_spawn!(escape)
      assert {:error, :containment_failed} = RouteGuard.own_process(guard, late)
      assert Process.whereis(name) == guard
      assert {:error, %{status: -2}} = GenServer.call(name, {:send_keys, "x"})
    end

    test "CC6 collectors are destroyed and joined BEFORE plain processes are drained, even when enrolled after them" do
      %{owner: owner, name: name, log: log, guard: guard, escape: escape} =
        control_boundary!(collector: false)

      test = self()

      # Enrolment order: a plain witness FIRST, the collector SECOND. Oldest-
      # first draining (the prior rule) would stop the witness before the
      # collector; the ruled order destroys and joins producers first.
      wtag = {:witness, make_ref()}
      Escape.reserve!(escape, wtag)
      {:ok, witness} = GenServer.start(TerminationWitness, %{escape: escape, tag: wtag, test: test})
      :ok = RouteGuard.own_process(guard, witness)

      collector = start_collector!(escape, guard, test: test)

      _root = chain_root!(collector, escape)
      assert_receive {:chain, :grandchild, _}, 2_000

      assert :ok = RouteGuard.contain!(owner)

      assert_receive {:collector_contained, ^collector, sealed_at}, 1_000
      assert_receive {:collector_destroyed, ^collector, destroyed_at}, 1_000
      assert_receive {:witness_terminated, ^witness, witness_at, %{collector_alive?: alive?}}, 1_000

      assert sealed_at < destroyed_at

      assert destroyed_at < witness_at,
             "the session must be destroyed before any plain process is drained (destroyed #{destroyed_at}, witness #{witness_at})"

      refute alive?, "the collector must already be joined when the first plain process is drained"
      refute Process.alive?(witness)

      RouteGuard.restore!(owner)
      assert [{:terminate, ^name}, {:restart, ^name}] = effects_log(log)
    end

    test "CC7 work created DURING containment, after the root's death, is discovered, joined and flushed (one-shot snapshot cannot pass)" do
      %{owner: owner, name: name, log: log, escape: escape, guard: guard} =
        control_boundary!(collector: false)

      holder = :ets.new(:cc7_child, [:public])

      # Seam: after the FIRST pid (the dead root) is joined and before its
      # flush, the collector asks the surviving child - synchronously - to
      # create one more process. That process exists only during containment.
      after_first_join = fn ->
        [{:child, child}] = :ets.lookup(holder, :child)
        send(child, {:spawn_more, self()})

        receive do
          {:spawned_late, late} -> :ets.insert(holder, {:late, late})
        after
          2_000 -> :ets.insert(holder, {:late, :handshake_failed})
        end
      end

      collector = start_collector!(escape, guard, after_first_join: after_first_join)

      root = chain_root!(collector, escape)
      assert_receive {:chain, :child, child}, 2_000
      assert_receive {:chain, :grandchild, _}, 2_000
      :ets.insert(holder, {:child, child})

      root_ref = Process.monitor(root)
      Process.exit(root, :kill)
      assert_receive {:DOWN, ^root_ref, :process, ^root, :killed}, 2_000

      assert :ok = RouteGuard.contain!(owner)

      [{:late, late}] = :ets.lookup(holder, :late)
      assert is_pid(late), "the during-containment handshake did not produce a process"
      refute Process.alive?(child)
      refute Process.alive?(late), "a process created DURING containment was not discovered/joined"

      RouteGuard.restore!(owner)
      assert [{:terminate, ^name}, {:restart, ^name}] = effects_log(log)
    end

    test "CC8 blocked startup: container stuck in its ready-on-return starter, the worker it spawned and a launcher-started inert coordinator are all joined; no report arrives" do
      %{owner: owner, name: name, log: log, escape: escape, collector: collector} =
        control_boundary!()

      test = self()

      # Reserve the worker and the inert coordinator BEFORE their starters run.
      wtag = {:worker, make_ref()}
      ctag = {:inert_coordinator, make_ref()}
      Escape.reserve!(escape, wtag)
      Escape.reserve!(escape, ctag)

      # A fixture starter through the REAL helpers: spawns a worker (as Boot
      # would spawn its reconciliation worker) and then blocks forever, so the
      # container never reports {:boot_started, _, _}.
      held_starter = fn _opts ->
        spawn(fn ->
          Escape.enroll!(escape, wtag)
          send(test, {:held_worker, self()})
          receive do: (:never -> :ok)
        end)

        receive do: (:never -> :ok)
      end

      inert =
        coordinator!(fn ->
          {:ok,
           spawn(fn ->
             Escape.enroll!(escape, ctag)
             receive do: (:never -> :ok)
           end)}
        end)

      container = boot_container!(held_starter) |> start_boot_in!(store: nil)
      assert_receive {:held_worker, worker}, 2_000
      refute_receive {:boot_started, ^container, _}, 200

      # B5: BOTH roots (container AND the coordinator launcher) are linked to
      # this test by the ordinary helpers so a failing product start takes a
      # RED row down with its reason. This control wants to observe the roots
      # die instead, so it unlinks every collector root first.
      for r <- ContainmentCollector.roots(collector), do: Process.unlink(r)

      assert :ok = RouteGuard.contain!(owner)

      refute Process.alive?(container), "the blocked container was not joined"
      refute Process.alive?(worker), "the starter's worker was not discovered/joined"
      refute Process.alive?(inert), "the launcher-started inert coordinator was not joined"
      refute_receive {:boot_started, ^container, _}, 50

      RouteGuard.restore!(owner)
      assert [{:terminate, ^name}, {:restart, ^name}] = effects_log(log)
    end

    test "CC9 NEGATIVE: a collector that merely REPORTS success leaves the chain alive - CC1's refutations can fail" do
      %{owner: owner, log: log, escape: escape, collector: collector} =
        control_boundary!(collector_opts: [contain_override: :ok])

      root = chain_root!(collector, escape)
      assert_receive {:chain, :child, child}, 2_000
      assert_receive {:chain, :grandchild, grandchild}, 2_000

      assert_raise RuntimeError, ~r/were not contained.*trace session not destroyed/s, fn ->
        RouteGuard.contain!(owner)
      end

      assert Process.alive?(root) and Process.alive?(child) and Process.alive?(grandchild),
             "a fake :ok performed no joins - the process-level assertions are what discriminate"

      assert_raise RuntimeError, ~r/containment unresolved/, fn -> RouteGuard.restore!(owner) end
      refute Enum.any?(effects_log(log), &match?({:restart, _}, &1))
    end

    test "CC10 an EXPIRED deadline over an empty owned set is a containment failure, not a pass" do
      %{owner: owner, log: log} = control_boundary!(collector: false, containment_budget_ms: 0)

      assert_raise RuntimeError, ~r/were not contained.*deadline/s, fn ->
        RouteGuard.contain!(owner)
      end

      assert_raise RuntimeError, ~r/containment unresolved/, fn -> RouteGuard.restore!(owner) end
      refute Enum.any?(effects_log(log), &match?({:restart, _}, &1))
    end

    test "CC11 ONE shared deadline: a collector that exhausts it leaves nothing for the plain drain, which is refused as expired" do
      %{owner: owner, log: log, guard: guard, escape: escape} =
        control_boundary!(collector: false, containment_budget_ms: 300)

      plain = escape_spawn!(escape)
      :ok = RouteGuard.own_process(guard, plain)
      _collector = start_collector!(escape, guard, answer_after_deadline: true)

      assert_raise RuntimeError, ~r/were not contained.*deadline expired/s, fn ->
        RouteGuard.contain!(owner)
      end

      assert Process.alive?(plain),
             "an expired drain must refuse, not stop the process on borrowed time"

      assert_raise RuntimeError, ~r/containment unresolved/, fn -> RouteGuard.restore!(owner) end
      refute Enum.any?(effects_log(log), &match?({:restart, _}, &1))
    end

    test "CC12 failed enrolment BEFORE start: a closed guard refuses the reservation and NO collector or session is created" do
      %{owner: owner, guard: guard, log: log} = control_boundary!(collector: false)

      assert :ok = RouteGuard.contain!(owner)
      assert nil == Process.whereis(ContainmentCollector)

      assert_raise RuntimeError, ~r/collector reservation refused/, fn ->
        ContainmentCollector.start_and_enroll!(guard)
      end

      assert nil == Process.whereis(ContainmentCollector),
             "a refused reservation must create nothing"

      RouteGuard.restore!(owner)
      assert Enum.any?(effects_log(log), &match?({:restart, _}, &1))
    end

    test "CC13 a root whose creator dies before release exits on its own; a late own after containment withholds restoration" do
      %{owner: owner, name: name, log: log, collector: collector, escape: escape} =
        control_boundary!()

      test = self()

      # A proxy creator (escape-owned) acquires a root and dies without
      # releasing it. The root is reserved with the escape before acquisition.
      rtag = {:root, make_ref()}
      Escape.reserve!(escape, rtag)

      proxy =
        escape_spawn!(escape, fn ->
          {:ok, root} = ContainmentCollector.acquire_root(collector, self(), fn -> :never end)
          Escape.fulfil!(escape, rtag, root)
          send(test, {:proxy_root, root})
          receive do: (:never -> :ok)
        end)

      assert_receive {:proxy_root, root}, 2_000
      root_ref = Process.monitor(root)
      Process.exit(proxy, :kill)
      assert_receive {:DOWN, ^root_ref, :process, ^root, :creator_gone}, 2_000

      assert :ok = RouteGuard.contain!(owner)
      refute Process.alive?(collector)

      # F1 (m_1789249820): a late request carrying an acquired resource is
      # refused AND leaves no stale contained:true - restoration is withheld.
      late = escape_spawn!(escape)
      assert {:error, :containment_closed} = RouteGuard.own_process(Process.whereis(name), late)
      assert_raise RuntimeError, ~r/containment unresolved/, fn -> RouteGuard.restore!(owner) end
      refute Enum.any?(effects_log(log), &match?({:restart, _}, &1))
      assert Process.alive?(late)
    end

    test "CC14 while containing, acquisition and release requests are ANSWERED with a refusal, never swallowed, and create nothing" do
      %{owner: owner, name: name, log: log, guard: guard, escape: escape} =
        control_boundary!(collector: false)

      test = self()
      holder = :ets.new(:cc14, [:public])
      # Reserved here; the callers are created inside the seam, by the collector.
      atag = {:acquirer, make_ref()}
      rtag = {:releaser, make_ref()}
      Escape.reserve!(escape, atag)
      Escape.reserve!(escape, rtag)
      forbidden = make_ref()

      # The seam runs INSIDE the collector after the first join. It creates two
      # escape-owned callers and then waits - bounded - until BOTH of their
      # requests are visible in the collector's own mailbox, so they are
      # guaranteed queued before the collector proceeds and therefore answered
      # (by the await loop while containing, or by the ordinary handler once
      # sealed) BEFORE the guard's destroy/stop. No race against :kill.
      after_first_join = fn ->
        [{:collector, c}] = :ets.lookup(holder, :collector)

        acquirer =
          spawn(fn ->
            Escape.enroll!(escape, atag)

            reply =
              ContainmentCollector.acquire_root(c, self(), fn ->
                send(test, {:forbidden_body_ran, forbidden})
              end)

            send(test, {:late_acquire, self(), reply})
            receive do: (:never -> :ok)
          end)

        releaser =
          spawn(fn ->
            Escape.enroll!(escape, rtag)
            send(test, {:late_release, self(), ContainmentCollector.release(c, self())})
            receive do: (:never -> :ok)
          end)

        queued? = fn ->
          {:messages, msgs} = Process.info(self(), :messages)

          Enum.any?(msgs, &match?({:"$gen_call", {^acquirer, _}, {:acquire_root, _, _}}, &1)) and
            Enum.any?(msgs, &match?({:"$gen_call", {^releaser, _}, {:release, _}}, &1))
        end

        wait_until!(
          queued?,
          System.monotonic_time(:millisecond) + 2_000,
          "both late requests queued"
        )
      end

      collector = start_collector!(escape, guard, after_first_join: after_first_join)
      :ets.insert(holder, {:collector, collector})

      _root = chain_root!(collector, escape)
      assert_receive {:chain, :child, _child}, 2_000
      assert_receive {:chain, :grandchild, _}, 2_000

      assert :ok = RouteGuard.contain!(owner)

      assert_receive {:late_acquire, acquirer, {:error, {:acquisition_closed, phase_a}}}, 2_000
      assert phase_a in [:closing, :sealed]
      assert_receive {:late_release, releaser, {:error, {:acquisition_closed, _}}}, 2_000

      refute_receive {:forbidden_body_ran, ^forbidden},
                     50,
                     "a refused acquisition must create and run nothing"

      refute Process.alive?(collector)

      # The callers are escape-owned; join them here as well (the escape would
      # otherwise join them at teardown).
      for p <- [acquirer, releaser] do
        ref = Process.monitor(p)
        Process.exit(p, :kill)
        assert_receive {:DOWN, ^ref, :process, ^p, :killed}, 1_000
      end

      RouteGuard.restore!(owner)
      assert [{:terminate, ^name}, {:restart, ^name}] = effects_log(log)
    end

    test "CC15 escape abort with a child HELD at its enrolment reply: creator killed; abort joins child and boundary; a newborn enrolling after the abort is accounted for and joined" do
      log = start_effects_log!()
      name = control_name()
      escape = Escape.start!(hold_enrolments: true)
      Escape.reserve!(escape, :guard)
      Escape.reserve!(escape, :owner)

      guard =
        RouteGuard.install!(name: name, effects: recording_effects(log), register_teardown: false)

      owner = RouteGuard.owner_of(guard)
      Escape.fulfil!(escape, :guard, guard)
      Escape.fulfil!(escape, :owner, owner)
      Escape.own_boundary!(escape, %{guard: guard, owner: owner, name: name})
      collector = start_collector!(escape, guard, [])

      test = self()
      ctag = {:child, make_ref()}
      ptag = {:creator, make_ref()}
      Escape.reserve!(escape, ptag)
      Escape.reserve!(escape, ctag)

      # The creator is fulfilled by this test after its spawn (an enrolment of
      # its own would be HELD by the seam and it could never spawn); the CHILD
      # enrols and is held at its reply - recorded, blocked, not yet running.
      creator =
        spawn(fn ->
          child =
            spawn(fn ->
              Escape.enroll!(escape, ctag)
              receive do: (:never -> :ok)
            end)

          send(test, {:held_child, child})
          receive do: (:never -> :ok)
        end)

      Escape.fulfil!(escape, ptag, creator)
      assert_receive {:held_child, child}, 2_000
      cref = Process.monitor(creator)
      Process.exit(creator, :kill)
      assert_receive {:DOWN, ^cref, :process, ^creator, :killed}, 2_000
      assert Process.alive?(child)

      wait_until!(
        fn -> child in Escape.recorded(escape) end,
        System.monotonic_time(:millisecond) + 2_000,
        "held child recorded"
      )

      # A newborn reserved BEFORE the abort but created only after it.
      ntag = {:newborn, make_ref()}
      Escape.reserve!(escape, ntag)

      summary = Escape.abort!(escape, 5_000)
      assert summary.fixture_unjoined == []
      assert summary.boundary_unjoined == []

      assert summary.pending == [ntag],
             "the unfulfilled newborn reservation must be reported, not cleared"

      refute Escape.resolved?(summary)
      refute Process.alive?(child)
      refute Process.alive?(collector)
      refute Process.alive?(guard)
      refute Process.alive?(owner)
      assert Process.whereis(name) == nil

      refute Enum.any?(effects_log(log), &match?({:restart, _}, &1)),
             "abort never calls the real restart"

      # The newborn enrols after the abort: recorded against its reservation,
      # refused, joined; the NEXT abort is then resolved. It is spawned PARKED
      # and monitored BEFORE it is released, so its DOWN reason is observed with
      # no window in which it could already be dead (A3: no :noproc).
      newborn =
        spawn(fn ->
          receive do: (:release -> :ok)
          Escape.enroll!(escape, ntag)
        end)

      nref = Process.monitor(newborn)
      send(newborn, :release)
      assert_receive {:DOWN, ^nref, :process, ^newborn, reason}, 2_000
      assert reason in [:escape_aborting, :killed]
      assert Escape.resolved?(Escape.abort!(escape, 5_000))
    end

    test "CC16 B1: a late own queued AHEAD of finalization vetoes restoration through the actual restore!; zero restart, guard retained and refusing" do
      %{owner: owner, name: name, log: log, guard: guard, escape: escape} = control_boundary!()
      test = self()
      assert :ok = RouteGuard.contain!(owner)

      late = escape_spawn!(escape)
      :ok = :sys.suspend(guard)

      try do
        # A: a late own carrying an acquired resource, queued first.
        a =
          escape_spawn!(escape, fn ->
            send(test, {:a_result, self(), RouteGuard.own_process(guard, late)})
            receive do: (:never -> :ok)
          end)

        wait_until!(
          fn ->
            {:messages, msgs} = Process.info(guard, :messages)
            Enum.any?(msgs, &match?({:"$gen_call", {^a, _}, {:own, {:process, ^late}}}, &1))
          end,
          System.monotonic_time(:millisecond) + 2_000,
          "late own queued on the suspended guard"
        )

        # B: restoration, whose :finalize is queued BEHIND the late own.
        b =
          escape_spawn!(escape, fn ->
            result =
              try do
                RouteGuard.restore!(owner)
                :restored
              rescue
                e -> {:raised, Exception.message(e)}
              end

            send(test, {:b_result, self(), result})
            receive do: (:never -> :ok)
          end)

        wait_until!(
          fn ->
            {:messages, msgs} = Process.info(guard, :messages)
            Enum.any?(msgs, &match?({:"$gen_call", {^b, _}, :finalize}, &1))
          end,
          System.monotonic_time(:millisecond) + 2_000,
          ":finalize queued behind the late own"
        )
      after
        :ok = :sys.resume(guard)
      end

      assert_receive {:a_result, _, {:error, :containment_closed}}, 2_000
      assert_receive {:b_result, _, {:raised, msg}}, 2_000
      assert msg =~ ~r/containment unresolved at finalization.*late_unaccounted/s

      refute Enum.any?(effects_log(log), &match?({:restart, _}, &1)),
             "a late acquisition acknowledged before finalization must veto the restart"

      assert Process.whereis(name) == guard, "the rejector is retained"
      assert Process.alive?(owner), "the registry is retained with it"
      assert {:error, %{status: -2}} = GenServer.call(name, :list_panes)
      assert Process.alive?(late)
    end

    test "CC17 B1: a guard that acknowledges finalization but does not stop -> restoration withheld, registry retained" do
      %{owner: owner, name: name, log: log, guard: guard} =
        control_boundary!(collector: false, finalize_mode: :ack_without_stop)

      assert :ok = RouteGuard.contain!(owner)

      assert_raise RuntimeError, ~r/acknowledged finalization but did not stop/, fn ->
        RouteGuard.restore!(owner)
      end

      refute Enum.any?(effects_log(log), &match?({:restart, _}, &1))
      assert Process.whereis(name) == guard
      assert Process.alive?(owner)
    end

    test "CC18 B2: a held pane supervisor makes the pane drain UNRESOLVED at the deadline with no worker process linked or abandoned; restoration withheld" do
      %{owner: owner, log: log, guard: guard} =
        control_boundary!(collector: false, containment_budget_ms: 300)

      pane_id = "%control-no-such-pane-#{System.unique_integer([:positive])}"
      :ok = RouteGuard.own_pane(guard, pane_id)
      sup = Process.whereis(AiPair.PaneSupervisor)
      assert is_pid(sup)

      {:links, links_before} = Process.info(self(), :links)
      :ok = :sys.suspend(sup)

      try do
        assert_raise RuntimeError, ~r/were not contained.*UNRESOLVED at the deadline/s, fn ->
          RouteGuard.contain!(owner)
        end
      after
        :ok = :sys.resume(sup)
      end

      {:links, links_after} = Process.info(self(), :links)

      assert Enum.sort(links_before) == Enum.sort(links_after),
             "no worker process may be linked to the drainer"

      assert_raise RuntimeError, ~r/containment unresolved/, fn -> RouteGuard.restore!(owner) end
      refute Enum.any?(effects_log(log), &match?({:restart, _}, &1))
    end

    test "CC19 B3: an arm failure whose kill/join succeeds retains the root as an UNARMED dead root; containment succeeds without a delivery proof for it" do
      %{owner: owner, name: name, log: log, collector: collector, escape: escape} =
        control_boundary!(collector_opts: [arm_override: {:error, :injected_arm_failure}])

      tag = {:root, make_ref()}
      Escape.reserve!(escape, tag)

      assert {:error, {:arm_failed, {:error, :injected_arm_failure}, :joined}} =
               ContainmentCollector.acquire_root(collector, self(), fn -> :never end)

      [root] = ContainmentCollector.roots(collector)
      Escape.fulfil!(escape, tag, root)
      refute Process.alive?(root), "the unarmed root must already be joined"

      assert :ok = RouteGuard.contain!(owner)
      RouteGuard.restore!(owner)
      assert [{:terminate, ^name}, {:restart, ^name}] = effects_log(log)
    end

    test "CC20 B3: an arm failure whose join is UNRESOLVED latches the acquisition; containment fails and restoration is withheld" do
      %{owner: owner, log: log, collector: collector, escape: escape} =
        control_boundary!(
          collector_opts: [arm_override: {:error, :injected}, join_override: :unjoined]
        )

      tag = {:root, make_ref()}
      Escape.reserve!(escape, tag)

      assert {:error, {:arm_failed, {:error, :injected}, :unjoined}} =
               ContainmentCollector.acquire_root(collector, self(), fn -> :never end)

      [root] = ContainmentCollector.roots(collector)
      Escape.fulfil!(escape, tag, root)

      assert_raise RuntimeError, ~r/were not contained.*unresolved_acquisition/s, fn ->
        RouteGuard.contain!(owner)
      end

      assert ContainmentCollector.phase(collector) == :failed
      assert_raise RuntimeError, ~r/containment unresolved/, fn -> RouteGuard.restore!(owner) end
      refute Enum.any?(effects_log(log), &match?({:restart, _}, &1))
    end

    test "CC21 B3: enrolment EXIT (guard dead after the reservation) destroys the EXACT acquired session; the reservation vetoes restoration" do
      %{owner: owner, log: log, guard: guard, escape: escape} = control_boundary!(collector: false)

      ref = make_ref()
      assert :ok = RouteGuard.reserve_collector(guard, ref)
      gref = Process.monitor(guard)
      Process.exit(guard, :kill)
      assert_receive {:DOWN, ^gref, :process, ^guard, :killed}, 2_000

      ptag = {:probe, make_ref()}
      Escape.reserve!(escape, ptag)

      assert {:error, {:enrollment_exit, _}} =
               GenServer.start(
                 ContainmentCollector,
                 [guard: guard, reservation: ref, session_probe: self()],
                 name: ContainmentCollector
               )

      assert_receive {:collector_session_probe, _collector, probe}, 2_000
      Escape.fulfil!(escape, ptag, probe)
      assert Process.alive?(probe)

      assert [] == :trace.session_info(probe),
             "no session may still trace the probe: the acquired session is gone (explicit destroy is source-verified, not discriminated from last-handle GC here)"

      assert nil == Process.whereis(ContainmentCollector)

      assert_raise RuntimeError, ~r/were not contained.*reservation never fulfilled/s, fn ->
        RouteGuard.contain!(owner)
      end

      assert_raise RuntimeError, ~r/containment unresolved/, fn -> RouteGuard.restore!(owner) end
      refute Enum.any?(effects_log(log), &match?({:restart, _}, &1))
    end

    test "CC22 B3: enrolment REFUSED (guard closed after the reservation) destroys the EXACT acquired session; the reservation vetoes restoration" do
      %{owner: owner, log: log, guard: guard, escape: escape} = control_boundary!(collector: false)

      ref = make_ref()
      assert :ok = RouteGuard.reserve_collector(guard, ref)

      # Closing the guard first makes the later fulfilment a RETURNED refusal.
      assert_raise RuntimeError, ~r/reservation never fulfilled/, fn ->
        RouteGuard.contain!(owner)
      end

      ptag = {:probe, make_ref()}
      Escape.reserve!(escape, ptag)

      assert {:error, {:enrollment_refused, {:error, :containment_failed}}} =
               GenServer.start(
                 ContainmentCollector,
                 [guard: guard, reservation: ref, session_probe: self()],
                 name: ContainmentCollector
               )

      assert_receive {:collector_session_probe, _collector, probe}, 2_000
      Escape.fulfil!(escape, ptag, probe)

      assert [] == :trace.session_info(probe),
             "no session may still trace the probe: the acquired session is gone (explicit destroy is source-verified, not discriminated from last-handle GC here)"

      assert nil == Process.whereis(ContainmentCollector)

      assert_raise RuntimeError, ~r/containment unresolved/, fn -> RouteGuard.restore!(owner) end
      refute Enum.any?(effects_log(log), &match?({:restart, _}, &1))
    end

    test "CC23 B4: a child killed-creator BEFORE its enrolment is an UNRESOLVED abort (escape retained), closed only once the child is joined" do
      %{escape: escape} = control_boundary!(collector: false)
      test = self()

      ctag = {:child, make_ref()}
      Escape.reserve!(escape, ctag)

      # The child waits for :proceed BEFORE enrolling: the pre-enrolment cut.
      creator =
        escape_spawn!(escape, fn ->
          child =
            spawn(fn ->
              receive do: (:proceed -> :ok)
              Escape.enroll!(escape, ctag)
              receive do: (:never -> :ok)
            end)

          send(test, {:pre_enrol_child, child})
          receive do: (:never -> :ok)
        end)

      assert_receive {:pre_enrol_child, child}, 2_000
      cref = Process.monitor(creator)
      Process.exit(creator, :kill)
      assert_receive {:DOWN, ^cref, :process, ^creator, :killed}, 2_000
      assert Process.alive?(child)

      # The registered teardown path itself must refuse to call this resolved.
      assert_raise RuntimeError, ~r/fixture cleanup UNRESOLVED/, fn -> Escape.teardown!(escape) end
      assert Process.alive?(escape), "unresolved cleanup keeps the escape and its evidence"
      assert [^ctag] = Escape.pending(escape)

      assert Process.alive?(child),
             "an unknown newborn cannot be joined yet - and is not pretended dead"

      # Closure: the child reaches its enrolment, is recorded against its
      # reservation, refused, and joined; only now is the abort resolved.
      chref = Process.monitor(child)
      send(child, :proceed)
      assert_receive {:DOWN, ^chref, :process, ^child, reason}, 2_000
      assert reason in [:escape_aborting, :killed]
      assert [] == Escape.pending(escape)
      assert Escape.resolved?(Escape.abort!(escape, 5_000))
    end

    test "CC24 B4: enrolments concurrent with abort are neither lost nor left live - queued ahead they are recorded and joined, queued behind they are drained, refused and joined" do
      %{escape: escape} = control_boundary!(collector: false)
      test = self()

      t1 = {:ahead, make_ref()}
      t2 = {:behind, make_ref()}
      Escape.reserve!(escape, t1)
      Escape.reserve!(escape, t2)

      # The abort CALLER is owned OUTSIDE the Escape it aborts (it must not be in
      # that Escape's kill set): parked, monitored, its kill+join registered with
      # on_exit BEFORE it is released (A2). It reports the summary to the test.
      aborter =
        spawn(fn ->
          receive do: (:release -> :ok)
          send(test, {:abort_summary, self(), Escape.abort!(escape, 5_000)})
          receive do: (:never -> :ok)
        end)

      # `abref` belongs to THIS test process and is used only by the in-row
      # join below. ExUnit runs exit callbacks in a different process
      # (on_exit_handler.ex:123-132 spawn_monitor), so the callback creates its
      # OWN monitor before the kill and raises if that DOWN does not arrive;
      # any reason - including :noproc for an aborter the row already joined -
      # is correct for idempotent cleanup (D2).
      abref = Process.monitor(aborter)

      on_exit(fn ->
        cref = Process.monitor(aborter)
        Process.exit(aborter, :kill)

        receive do
          {:DOWN, ^cref, :process, ^aborter, _} -> :ok
        after
          1_000 -> raise "CC24 aborter #{inspect(aborter)} did not terminate; cleanup unwitnessed"
        end
      end)

      :ok = :sys.suspend(escape)

      # Everything between suspend and resume is guarded: a failed wait must not
      # strand the Escape (and with it the registered teardown) suspended. Both
      # child monitors are acquired IN HERE, while the Escape is still suspended
      # and so cannot yet have killed either child (D1): a monitor taken after
      # resume could find them already dead and report :noproc.
      {ahead, aref, behind, bref} =
        try do
          ahead =
            spawn(fn ->
              Escape.enroll!(escape, t1)
              receive do: (:never -> :ok)
            end)

          aref = Process.monitor(ahead)

          wait_until!(
            fn ->
              {:messages, msgs} = Process.info(escape, :messages)
              Enum.any?(msgs, &match?({:"$gen_call", {^ahead, _}, {:enroll, ^t1}}, &1))
            end,
            System.monotonic_time(:millisecond) + 2_000,
            "enrolment queued ahead of abort"
          )

          send(aborter, :release)

          wait_until!(
            fn ->
              {:messages, msgs} = Process.info(escape, :messages)
              Enum.any?(msgs, &match?({:"$gen_call", {^aborter, _}, {:abort, _}}, &1))
            end,
            System.monotonic_time(:millisecond) + 2_000,
            "abort queued"
          )

          behind =
            spawn(fn ->
              Escape.enroll!(escape, t2)
              receive do: (:never -> :ok)
            end)

          bref = Process.monitor(behind)

          wait_until!(
            fn ->
              {:messages, msgs} = Process.info(escape, :messages)
              Enum.any?(msgs, &match?({:"$gen_call", {^behind, _}, {:enroll, ^t2}}, &1))
            end,
            System.monotonic_time(:millisecond) + 2_000,
            "enrolment queued behind abort"
          )

          {ahead, aref, behind, bref}
        after
          :ok = :sys.resume(escape)
        end

      # SERVER-SIDE witnesses (A2): the Escape's own record is the oracle, not a
      # message the child may never get to send. `ahead` was recorded by the
      # enrolment processed BEFORE the abort; `behind` was recorded by the
      # abort's drain of the enrolment queued BEHIND it; neither reservation is
      # pending; the summary is resolved; both children are joined.
      assert_receive {:abort_summary, ^aborter, summary}, 6_000
      recorded = Escape.recorded(escape)
      assert ahead in recorded, "the enrolment queued ahead of the abort must have been recorded"

      assert behind in recorded,
             "the enrolment queued behind the abort must have been drained and recorded"

      assert [] == Escape.pending(escape), "both reservations must be resolved, not dropped"
      assert Escape.resolved?(summary), "both newborns must be accounted for: #{inspect(summary)}"
      assert_receive {:DOWN, ^aref, :process, ^ahead, :killed}, 2_000
      assert_receive {:DOWN, ^bref, :process, ^behind, reason}, 2_000
      assert reason in [:escape_aborting, :killed]

      # The aborter is joined here as well as by its on_exit.
      Process.exit(aborter, :kill)
      assert_receive {:DOWN, ^abref, :process, ^aborter, :killed}, 2_000
    end

    test "CC25 B4: a reservation never fulfilled fails the REGISTERED teardown path and keeps the escape; fulfilment with a joined process resolves it" do
      %{escape: escape} = control_boundary!(collector: false)

      tag = {:never_created, make_ref()}
      Escape.reserve!(escape, tag)

      assert_raise RuntimeError, ~r/fixture cleanup UNRESOLVED.*never_created/s, fn ->
        Escape.teardown!(escape)
      end

      assert Process.alive?(escape)
      assert [^tag] = Escape.pending(escape)

      # Account for it: the resource turns out to be this parked process; the
      # next abort joins it and the summary resolves.
      stray = spawn(fn -> receive do: (:never -> :ok) end)
      Escape.fulfil!(escape, tag, stray)
      summary = Escape.abort!(escape, 5_000)
      assert Escape.resolved?(summary)
      refute Process.alive?(stray)
    end
  end

  # ===== fixtures for the containment controls =====

  # Boundary for one control, in the ruled order: escape FIRST (its on_exit is
  # the independent cleanup), reservations for the boundary, then an inert-
  # recorder guard under a private name (fulfilled), then - unless `collector:
  # false` - a collector reserved with the escape and enrolled with the guard
  # through the real protocol.
  defp control_boundary!(opts \\ []) do
    log = start_effects_log!()
    name = control_name()
    escape = Escape.start!()
    Escape.reserve!(escape, :guard)
    Escape.reserve!(escape, :owner)

    guard =
      RouteGuard.install!(
        name: name,
        effects: recording_effects(log),
        register_teardown: false,
        containment_budget_ms: Keyword.get(opts, :containment_budget_ms, 10_000),
        finalize_mode: Keyword.get(opts, :finalize_mode, :stop)
      )

    owner = RouteGuard.owner_of(guard)
    Escape.fulfil!(escape, :guard, guard)
    Escape.fulfil!(escape, :owner, owner)
    Escape.own_boundary!(escape, %{guard: guard, owner: owner, name: name})
    assert [{:terminate, ^name}] = effects_log(log)

    collector =
      if Keyword.get(opts, :collector, true),
        do: start_collector!(escape, guard, Keyword.get(opts, :collector_opts, [])),
        else: nil

    %{log: log, name: name, escape: escape, guard: guard, owner: owner, collector: collector}
  end

  # Reserve with the escape, start through the real guard protocol, fulfil and
  # record as boundary.
  defp start_collector!(escape, guard, opts) do
    tag = {:collector, make_ref()}
    Escape.reserve!(escape, tag)
    collector = ContainmentCollector.start_and_enroll!(guard, opts)
    Escape.fulfil!(escape, tag, collector)
    Escape.own_boundary!(escape, %{collector: collector})
    collector
  end

  # A chain root created THROUGH the collector (reserve, acquire, fulfil,
  # release): after :go it spawns child -> grandchild, each RESERVED by its
  # parent before the spawn and each enrolling as its first action, each
  # reported to the test, and parks forever. `child` creates one more on
  # {:spawn_more, from} (reserved first) and answers {:spawned_late, pid}.
  # Plain spawn throughout: no links, no names.
  defp chain_root!(collector, escape) do
    test = self()
    rtag = {:root, make_ref()}
    Escape.reserve!(escape, rtag)

    {:ok, root} =
      ContainmentCollector.acquire_root(collector, test, fn ->
        ctag = {:child, make_ref()}
        Escape.reserve!(escape, ctag)

        child =
          spawn(fn ->
            Escape.enroll!(escape, ctag)
            gtag = {:grandchild, make_ref()}
            Escape.reserve!(escape, gtag)

            grandchild =
              spawn(fn ->
                Escape.enroll!(escape, gtag)
                receive do: (:never -> :ok)
              end)

            send(test, {:chain, :grandchild, grandchild})
            chain_child_loop(escape)
          end)

        send(test, {:chain, :child, child})
        receive do: (:never -> :ok)
      end)

    Escape.fulfil!(escape, rtag, root)
    :ok = ContainmentCollector.release(collector, root)
    root
  end

  defp chain_child_loop(escape) do
    receive do
      {:spawn_more, from} ->
        ltag = {:late, make_ref()}
        Escape.reserve!(escape, ltag)

        late =
          spawn(fn ->
            Escape.enroll!(escape, ltag)
            receive do: (:never -> :ok)
          end)

        send(from, {:spawned_late, late})
        chain_child_loop(escape)
    end
  end

  # A plain, escape-reserved-and-recorded process (not under the collector)
  # running `body` after enrolment; defaults to parking forever.
  defp escape_spawn!(escape, body \\ fn -> receive do: (:never -> :ok) end) do
    test = self()
    tag = {:spawn, make_ref()}
    Escape.reserve!(escape, tag)

    pid =
      spawn(fn ->
        Escape.enroll!(escape, tag)
        send(test, {:escape_spawned, self()})
        body.()
      end)

    assert_receive {:escape_spawned, ^pid}, 2_000
    pid
  end

  # Bounded predicate wait for the mailbox handshakes; raises with the label
  # when the deadline passes. Not a stability sleep: it waits for a specific
  # observable condition and fails if it never holds.
  defp wait_until!(pred, deadline, label) do
    cond do
      pred.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "condition not reached in time: #{label}"

      true ->
        receive do
        after
          5 -> wait_until!(pred, deadline, label)
        end
    end
  end

  # ===== inert collaborators for the containment controls (as in quarantine_test) =====

  defp recording_effects(log) do
    %{
      terminate_child: fn _sup, name ->
        Agent.update(log, &[{:terminate, name} | &1])
        :ok
      end,
      restart_child: fn _sup, name ->
        Agent.update(log, &[{:restart, name} | &1])
        {:ok, self()}
      end
    }
  end

  defp effects_log(log), do: Agent.get(log, &Enum.reverse(&1))

  defp start_effects_log! do
    start_supervised!({Agent, fn -> [] end}, id: {:effects_log, System.unique_integer([:positive])})
  end

  defp control_name, do: :"boot_wiring_guard_control_#{System.unique_integer([:positive])}"

  # ===== fixtures for the boundary, B1 and T2 rows =====

  # The request ops the PRODUCT adapter serves, read from its source rather than
  # restated here, so a call shape added to `AiPair.Tmux` without a matching row
  # above fails this file instead of slipping past the boundary unexercised.
  defp adapter_request_ops do
    path = Path.join([File.cwd!(), "lib", "ai_pair", "tmux.ex"])

    assert File.exists?(path), "cannot read the adapter source at #{path}; the check would be blind"

    ops =
      ~r/^  def handle_call\(\{?:([a-z_]+)/m
      |> Regex.scan(File.read!(path))
      |> Enum.map(fn [_, op] -> String.to_atom(op) end)

    assert length(ops) >= 11,
           "only #{length(ops)} handle_call clauses parsed from #{path}; the check is blind"

    ops
  end

  # An owned adapter bound to a fixture `tmux` that never execs the real binary:
  # empty stdout, exit 0. Modelled on tmux_census_test.exs's fake runner.
  defp fake_tmux! do
    dir = Path.join(System.tmp_dir!(), "s11_boundary_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    bin = Path.join(dir, "tmux")
    File.write!(bin, "#!/bin/bash\nexit 0\n")
    File.chmod!(bin, 0o700)

    name = String.to_atom("s11_fake_tmux_#{System.unique_integer([:positive])}")

    start_supervised!(
      Supervisor.child_spec({Tmux, [name: name, tmux_bin: bin, socket_name: nil]}, id: name)
    )

    {name, dir}
  end

  # A valid pane coordinate built at runtime so no literal %<digits> appears in
  # this file (redaction scanner) and so no live pane is claimed behind it.
  defp synthetic_pane_id, do: "%" <> Integer.to_string(System.unique_integer([:positive]))

  defp child_ids do
    AiPair.Supervisor
    |> Supervisor.which_children()
    |> Enum.map(fn {id, _pid, _type, _mods} -> id end)
  end

  defp inbox_root! do
    inbox = Path.join(System.tmp_dir!(), "ai_pair_s11_inbox_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(inbox) end)
    File.mkdir_p!(Path.join(inbox, "sock"))
    File.chmod!(inbox, 0o700)
    File.chmod!(Path.join(inbox, "sock"), 0o700)
    inbox
  end

  # A standalone IPC server for the rows that do not boot the Application.
  # Stop-and-join is registered before the server can be used.
  defp ipc_server!(inbox, name) do
    {:ok, ipc} = AiPair.Test.ReceiptBackedIPCServer.start_link(inbox: inbox, name: name)
    on_exit(fn -> RouteGuard.stop_and_join!(ipc, 1_000) end)
    {:ok, ipc}
  end

  # ===== containment-control roots (lane text; the `starter` defaults are
  # ===== dropped because only the controls' injected starters are used here,
  # ===== and an unused default argument is a compiler warning the gate treats
  # ===== as an error) =====

  # Boot lifecycle container. The container is CREATED BY the file's
  # ContainmentCollector (acquire_root/3): spawned PARKED, armed on the
  # collector's dedicated trace session and recorded as owned before this row
  # learns its pid; the row then links it (failure propagation, not ownership)
  # and asks the collector to release it.
  defp boot_container!(starter) do
    test = self()
    acquire_and_release_root!(fn -> container_loop(test, starter) end)
  end

  defp container_loop(test, starter) do
    receive do
      {:start, opts} ->
        send(test, {:boot_started, self(), starter.(opts)})
        container_loop(test, starter)

      :stop ->
        :ok
    end
  end

  # Create-armed-owned, link, release: through the enrolled collector only.
  defp acquire_and_release_root!(body) do
    collector = ContainmentCollector.current!()

    root =
      case ContainmentCollector.acquire_root(collector, self(), body) do
        {:ok, root} -> root
        {:error, reason} -> raise "root acquisition refused: #{inspect(reason)}"
      end

    Process.link(root)

    case ContainmentCollector.release(collector, root) do
      :ok -> root
      {:error, reason} -> raise "root release refused: #{inspect(reason)}"
    end
  end

  # Ask the container to start its subject; returns the container so the row can
  # act while the starter is still blocked inside it.
  defp start_boot_in!(container, opts) do
    send(container, {:start, opts})
    container
  end

  # The coordinator stand-in is started from a PARKED, armed launcher root
  # created exactly like the Boot container, so it and anything it spawns are
  # the collector's provenance descendants. The launcher stays alive as the link
  # parent for the row and TRAPS EXITS.
  defp coordinator!(starter) do
    test = self()

    launcher =
      acquire_and_release_root!(fn ->
        Process.flag(:trap_exit, true)
        send(test, {:coordinator_started, self(), starter.()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:coordinator_started, ^launcher, result}, 5_000
    assert {:ok, pid} = result, "the coordinator stand-in did not start under the launcher"
    pid
  end
end
