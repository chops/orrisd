defmodule AiPair.ApplicationDurableBootTest.ControlledStore do
  # A store double addressable exactly as `AiPair.PaneIntentStore` is, carried
  # from the reviewed RED (`56b5c7b:test/ai_pair/pane_restore/boot_wiring_test.exs`,
  # its `ControlledStore`) with only the members these rows use.
  #
  # PROTOCOL-FAITHFUL: `:list` is answered `{:ok, rows}` exactly as
  # `pane_intent_store.ex:155-156` answers it - the shape `Reconciler` consumes
  # - never a bare list, and every call is reported to the test WITH ITS CALLER
  # PID, so the actual GenServer caller of a source read (the reconciliation
  # worker) is known to the row rather than inferred.
  #
  # TRUSTED STORE MODULE: started by the Application through
  # `:pane_intent_store_module` it receives exactly `root:`/`fs:`; it then
  # registers under `{:global, {AiPair.PaneIntentStore, Path.expand(root)}}` -
  # the key `ipc/server.ex:815` resolves - and takes its test-owned options
  # (`test:`, `records:`, `hold:`, `list_error:`) from the
  # `:application_durable_boot_store` application key, which every row that
  # configures it snapshots and restores with the rest.
  use GenServer

  def start_link(opts) do
    opts = Keyword.merge(Application.get_env(:ai_pair, :application_durable_boot_store, []), opts)

    server_opts =
      case Keyword.fetch(opts, :root) do
        {:ok, root} -> [name: {:global, {AiPair.PaneIntentStore, Path.expand(root)}}]
        :error -> Keyword.take(opts, [:name])
      end

    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       test: Keyword.fetch!(opts, :test),
       records: Enum.sort_by(Keyword.get(opts, :records, []), & &1["pane_id"]),
       # nil, or an {:error, error()} every :list answers with instead of records
       list_error: Keyword.get(opts, :list_error),
       # :none | {:hold_on, n} - the nth :list notifies the test and blocks
       hold: Keyword.get(opts, :hold, :none),
       calls: 0,
       held_from: nil
     }}
  end

  @impl true
  def handle_call(:list, {caller, _tag} = from, state) do
    n = state.calls + 1
    state = %{state | calls: n}
    send(state.test, {:store_list, n, self(), caller})

    case state.hold do
      {:hold_on, ^n} ->
        send(state.test, {:store_list_held, n, self(), caller})
        {:noreply, %{state | held_from: from}}

      _ ->
        {:reply, list_reply(state), state}
    end
  end

  def handle_call({:put, record}, {caller, _tag}, state) do
    send(state.test, {:store_put, record, caller})
    others = Enum.reject(state.records, &(&1["pane_id"] == record["pane_id"]))
    {:reply, :ok, %{state | records: Enum.sort_by([record | others], & &1["pane_id"])}}
  end

  def handle_call({:delete, pane_id}, {caller, _tag}, state) do
    send(state.test, {:store_delete, pane_id, caller})
    {:reply, :ok, %{state | records: Enum.reject(state.records, &(&1["pane_id"] == pane_id))}}
  end

  @impl true
  def handle_info(:release, %{held_from: from} = state) when from != nil do
    GenServer.reply(from, list_reply(state))
    {:noreply, %{state | held_from: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp list_reply(%{list_error: nil, records: records}), do: {:ok, records}
  defp list_reply(%{list_error: error}), do: error
end

defmodule AiPair.ApplicationDurableBootTest.UnregisteredStore do
  # OQ-2's subject: a `:pane_intent_store_module` that STARTS but never claims
  # the `:global` key the contract requires of it. It is a caller defect the
  # contract says S10 does not check; this module exists so the row can measure
  # what the daemon actually does with one instead of leaving it latent.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def handle_call(:list, _from, state), do: {:reply, {:ok, []}, state}
end

defmodule AiPair.ApplicationDurableBootTest do
  @moduledoc """
  The R04 S10 producer rows: `AiPair.Application`'s durable branch, measured by
  booting the ACTUAL application under a fixture inbox.

  Contract: `docs/contracts/durable-mode-configuration.org`, frozen on main at
  `15ae50e`/`a3a11e6`, whose tables are pinned byte-for-byte by
  `test/ai_pair/contracts/durable_mode_configuration_test.exs`. That suite pins
  the LEGACY branch and the frozen tables; this one is the producer's own
  measurement, and the two are complementary: a durable branch that passed there
  and did nothing would fail here.

  ## Rows carried from the reviewed RED

  `56b5c7b:test/ai_pair/pane_restore/boot_wiring_test.exs`. The S11 port
  (`R04-S11-RECORD.org`, section 4) classified B2, B5a and B5b PORTED-PENDING
  S10 because each needs the durable Application and its full-application
  fixture; all three are carried here and now pass. G9 was classified
  NOT-PORTABLE because its fixture starts a LIVE tmux server
  (`start_sessions!/2` runs `tmux -L <socket> new-session`), which this run
  forbids; its `:boot_generation` half - the one that belongs to S10 - needs no
  tmux server at all and is carried, with the cross-session marker half left
  NOT-PORTABLE and recorded. A row whose fixture cannot be built truthfully is
  listed, never weakened into a green assertion.

  ## Containment

  These rows own the boot, so they cannot install `AiPair.Test.RouteGuard`: the
  guard holds the `AiPair.Tmux` registered name and the application's own
  adapter child would then fail to start. The boundary is the RED's instead - a
  refusing Bash `tmux` put FIRST on PATH before the application starts and taken
  off only after `Application.stop/1` has joined the tree - and every full-app
  row proves that boundary is live BEFORE the boot it measures
  (`refused_path_control!/1`) and that the application's OWN adapter child
  routes into it (`refused_app_adapter_control!/2`). Its limit is stated where
  it is built: it binds the `tmux` resolved from PATH and nothing else.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AiPair.ApplicationDurableBootTest.ControlledStore
  alias AiPair.ApplicationDurableBootTest.UnregisteredStore
  alias AiPair.PaneIntentStore
  alias AiPair.PaneRestore.Boot
  alias AiPair.PaneRestore.Coordinator
  alias AiPair.Test.PaneIntentFaultFs, as: FaultFs
  alias AiPair.Test.ScriptedTmux
  alias AiPair.Tmux

  @marker_option "@ai_pair_session_incarnation"
  @wrapper_refusal_status 97

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

  # The eleven children a durable boot starts, in `which_children` order: the
  # reverse of the contract's frozen start order.
  @durable_child_ids [
    AiPair.IPC.Server,
    AiPair.Delivery.ReceiptStore,
    AiPair.IPC.ConnectionSupervisor,
    AiPair.PaneRestore.Boot,
    AiPair.PaneIntentStore,
    AiPair.PaneRestore.Coordinator,
    AiPair.Tmux,
    AiPair.Inbox.StuckScanner,
    AiPair.PaneSupervisor,
    AiPair.Telemetry.OtelBridge,
    AiPair.Registry
  ]

  # =========================================================================
  # The durable composition (B2)
  # =========================================================================

  describe "durable boot composition" do
    test "B2 the store is resolvable by the server's exact :global key, beside the Coordinator" do
      inbox = inbox_root!()
      {wrapper_dir, log} = refusing_tmux_on_path!()

      # No `:tmux_server`, so the census and every marker read resolve `tmux`
      # from PATH into the wrapper, which answers an EMPTY server: the boot has
      # nothing to reconcile and must still start the store and the Coordinator.
      baseline =
        full_app_env!(inbox, wrapper_dir, fn ->
          Application.put_env(:ai_pair, :durable_attachments, true)
          Application.delete_env(:ai_pair, :tmux_server)
          Application.delete_env(:ai_pair, :boot_generation)
          Application.delete_env(:ai_pair, :pane_intent_store_fs)
          Application.delete_env(:ai_pair, :pane_intent_store_module)
          Application.put_env(:ai_pair, :project_binding, binding_for(inbox))
          refused_path_control!(log)
        end)

      assert {:ok, _} = start_app!()

      # The exact key `ipc/server.ex:815` resolves.
      store = :global.whereis_name({PaneIntentStore, Path.expand(inbox)})
      assert is_pid(store), "durable boot did not register the store under the server's :global key"
      assert {:ok, _records} = PaneIntentStore.list(store)
      assert is_pid(Process.whereis(Coordinator)), "durable boot did not start the Coordinator"

      # The whole composition, in the frozen order, and the three new children
      # at the positions the contract's edges require.
      assert child_ids() == @durable_child_ids

      assert {:ok, ^store} = app_child(PaneIntentStore)
      assert {:ok, boot} = app_child(Boot)
      assert {:ok, _ipc} = app_child(AiPair.IPC.Server)

      # `Boot` is ready on return, so by the time `start_app!/0` answered the one
      # reconciliation attempt had settled and its report was published.
      status = Boot.status(boot)
      assert {:completed, worker} = status.reconciliation
      refute Process.alive?(worker)
      assert status.report.panes == []
      assert status.report.root == inbox
      assert File.exists?(Boot.report_path(inbox))

      # An empty server has no session to mark: a durable boot that wrote a
      # marker anyway, or minted one for an invented session, is caught here.
      assert marker_set_attempts(log) == baseline,
             "durable boot with no sessions attempted a marker write: #{inspect(wrapper_lines(log))}"

      refused_app_adapter_control!(log, baseline)
    end
  end

  # =========================================================================
  # Fail closed (B5a, G9's boot_generation half)
  # =========================================================================

  describe "what fails the boot" do
    test "B5a an unstartable store child fails the boot closed, with nothing serving" do
      inbox = inbox_root!()
      {wrapper_dir, _log} = refusing_tmux_on_path!()
      sock_path = Path.join(inbox, "sock/ai-pair.sock")

      # The fault is injected THROUGH the forwarded handle at the store's FIRST
      # fallible acquisition - `Fs.lstat/2` on the resolved root itself - while
      # inbox resolution stays healthy, because `AiPair.Inbox.resolve!/0` uses
      # `File` directly and never this seam. So the only way this fault can fire
      # is that the store child was started at the resolved root with the
      # forwarded handle, and the fired-fault witness below proves the start was
      # REACHED and failed there rather than some unrelated config error
      # aborting the boot.
      fs = FaultFs.new()
      on_exit(fn -> FaultFs.stop(fs) end)
      root_lstat? = fn [path] -> path == inbox end
      :ok = FaultFs.inject(fs, :lstat, root_lstat?, {:error, :eacces})

      full_app_env!(inbox, wrapper_dir, fn ->
        Application.put_env(:ai_pair, :durable_attachments, true)
        Application.delete_env(:ai_pair, :tmux_server)
        Application.delete_env(:ai_pair, :boot_generation)
        Application.delete_env(:ai_pair, :pane_intent_store_module)
        Application.put_env(:ai_pair, :pane_intent_store_fs, fs)
        Application.put_env(:ai_pair, :project_binding, binding_for(inbox))
      end)

      result = start_app!()

      assert FaultFs.fault_fired?(fs, :lstat, root_lstat?),
             "the store child never reached its root acquisition through the forwarded fs; " <>
               "whatever failed, it was not the store start (ops: #{inspect(FaultFs.ops(fs))})"

      assert match?({:error, _}, result),
             "durable boot with an unstartable store must fail closed, got: #{inspect(result)}"

      assert Process.whereis(AiPair.Supervisor) == nil,
             "a failed durable boot must leave nothing serving"

      assert Process.whereis(AiPair.IPC.Server) == nil, "no IPC child may survive a failed boot"
      refute File.exists?(sock_path), "a failed durable boot must not leave a socket behind"

      refute listener_alive?(sock_path),
             "nothing may accept on the fixture socket after a failed boot"
    end

    test "G9 (boot_generation half) a present-invalid generation fails closed before any child" do
      inbox = inbox_root!()
      {wrapper_dir, log} = refusing_tmux_on_path!()
      me = self()
      pinned = decimal_generation()

      # The store is the controlled double so that "no child was started" is a
      # MEASURED absence of its `:list`, not an inference: a boot that validated
      # the generation only inside `AiPair.IPC.Server.start_link/1`, where main
      # already validates it, would have run the store and a whole reconciliation
      # first and this row would receive the message.
      baseline =
        full_app_env!(inbox, wrapper_dir, fn ->
          Application.put_env(:ai_pair, :durable_attachments, true)
          Application.delete_env(:ai_pair, :tmux_server)
          Application.delete_env(:ai_pair, :pane_intent_store_fs)
          Application.put_env(:ai_pair, :pane_intent_store_module, ControlledStore)
          Application.put_env(:ai_pair, :application_durable_boot_store, test: me, records: [])
          Application.put_env(:ai_pair, :project_binding, binding_for(inbox))
          Application.put_env(:ai_pair, :boot_generation, "not-a-decimal")
          refused_path_control!(log)
        end)

      assert {:error, _} = start_app!()

      assert Process.whereis(AiPair.Supervisor) == nil,
             "a rejected boot_generation must fail the boot closed"

      refute_receive {:store_list, _, _, _},
                     200,
                     "a rejected boot_generation reached the store child; it must be validated " <>
                       "BEFORE the child list is built"

      refute File.exists?(Boot.report_path(inbox)),
             "a rejected boot_generation reached reconciliation and published a report"

      assert marker_set_attempts(log) == baseline,
             "a rejected boot_generation must not even attempt a marker write"

      # POSITIVE CONTROL, same composition and the same store double: with a
      # pinned DECIMAL generation the boot succeeds and the store IS listed, so
      # the refutations above discriminate the generation and not the fixture.
      stop_app!()
      Application.put_env(:ai_pair, :boot_generation, pinned)
      assert {:ok, _} = start_app!()
      assert_receive {:store_list, 1, _store, _worker}, 5_000
      assert {:ok, _boot} = app_child(Boot)
      assert %{"ok" => true, "pong" => _} = ping!(Path.join(inbox, "sock/ai-pair.sock"))
    end

    test "the fetch_env rule: absence mints, but an explicit nil is a present value that fails" do
      inbox = inbox_root!()
      {wrapper_dir, log} = refusing_tmux_on_path!()

      # ABSENT: `fetch_env` answers `:error`, the only absence, and the boot
      # mints its own generation and comes up.
      full_app_env!(inbox, wrapper_dir, fn ->
        Application.put_env(:ai_pair, :durable_attachments, true)
        Application.delete_env(:ai_pair, :tmux_server)
        Application.delete_env(:ai_pair, :pane_intent_store_fs)
        Application.delete_env(:ai_pair, :pane_intent_store_module)
        Application.delete_env(:ai_pair, :boot_generation)
        Application.put_env(:ai_pair, :project_binding, binding_for(inbox))
        refused_path_control!(log)
      end)

      assert {:ok, _} = start_app!()
      assert {:ok, _ipc} = app_child(AiPair.IPC.Server)

      # PRESENT and useless. Under the `get_env(...) || mint` spelling the r8
      # proposal text used, each of these would SILENTLY mint; under the
      # `fetch_env` ruling the contract states, each is a present value that
      # fails the decimal check and fails the boot.
      for value <- [nil, false, "", "12 34", "12\n", 7] do
        stop_app!()
        Application.put_env(:ai_pair, :boot_generation, value)

        assert {:error, _} = start_app!(),
               "boot_generation #{inspect(value)} must fail the boot, not be minted over"

        assert Process.whereis(AiPair.Supervisor) == nil
      end
    end
  end

  # =========================================================================
  # The Boot-before-IPC edge (B5b): the load-bearing one
  # =========================================================================

  describe "ordering" do
    test "B5b a held boot-time :list keeps the IPC server unstarted, and its failure is reported" do
      inbox = inbox_root!()
      {wrapper_dir, _log} = refusing_tmux_on_path!()
      sock_path = Path.join(inbox, "sock/ai-pair.sock")
      store_key = {PaneIntentStore, Path.expand(inbox)}
      me = self()

      list_error =
        {:error, %{stage: :read, reason: :induced, outcome: :unchanged, cleanup_errors: []}}

      full_app_env!(inbox, wrapper_dir, fn ->
        Application.put_env(:ai_pair, :durable_attachments, true)
        Application.delete_env(:ai_pair, :tmux_server)
        Application.delete_env(:ai_pair, :boot_generation)
        Application.delete_env(:ai_pair, :pane_intent_store_fs)
        Application.put_env(:ai_pair, :pane_intent_store_module, ControlledStore)

        Application.put_env(:ai_pair, :application_durable_boot_store,
          test: me,
          records: [],
          list_error: list_error,
          hold: {:hold_on, 1}
        )

        Application.put_env(:ai_pair, :project_binding, binding_for(inbox))
      end)

      # Whatever happens below, the held store child is released before the
      # environment teardown stops the application (LIFO: registered after it).
      on_exit(fn ->
        case :global.whereis_name(store_key) do
          pid when is_pid(pid) -> send(pid, :release)
          :undefined -> :ok
        end
      end)

      # ---- held phase: the actual Application startup blocks at Boot's list ----
      starter = Task.async(fn -> start_app!() end)
      own_task!(starter)

      assert_receive {:store_list_held, 1, store, worker}, 5_000
      assert_receive {:store_list, 1, ^store, ^worker}, 1_000
      worker_ref = Process.monitor(worker)

      assert :global.whereis_name(store_key) == store,
             "the configured store module must be the owner under the server's exact key"

      assert is_pid(Process.whereis(AiPair.Supervisor)), "Application startup must be in progress"

      assert Process.alive?(worker),
             "the reconciliation worker must be the one waiting on the store"

      # `Supervisor.which_children/1` is NOT called while held: the supervisor is
      # inside `init/1` starting children and would not answer, so child identity
      # while held is read from the registered IPC name instead.
      assert Process.whereis(AiPair.IPC.Server) == nil, "IPC started before Boot settled"

      refute listener_alive?(sock_path),
             "something accepts on the fixture socket before Boot settled"

      refute File.exists?(sock_path), "the IPC socket exists before Boot settled"

      send(store, :release)
      assert {:ok, _} = Task.await(starter, 15_000)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 5_000

      # ---- the finished composition ----
      assert {:ok, ^store} = app_child(PaneIntentStore)
      assert {:ok, boot} = app_child(Boot)
      assert {:ok, _ipc} = app_child(AiPair.IPC.Server)
      assert %{"ok" => true, "pong" => _} = ping!(sock_path)

      status = Boot.status(boot)
      assert {:completed, ^worker} = status.reconciliation
      assert status.report.panes == []

      assert Enum.any?(
               status.report.issues,
               &match?({:source_error, :intent, %{reason: :induced}}, &1)
             ),
             "issues must carry the selected intent-source error, got: #{inspect(status.report.issues)}"

      # ---- positive control: same composition, no hold, no error ----
      stop_app!()
      Application.put_env(:ai_pair, :application_durable_boot_store, test: me, records: [])
      assert {:ok, _} = start_app!()
      assert_receive {:store_list, 1, control_store, control_worker}, 5_000
      refute control_store == store, "the control must run a fresh store child"
      assert {:ok, ^control_store} = app_child(PaneIntentStore)
      assert %{"ok" => true, "pong" => _} = ping!(sock_path)
      assert {:ok, control_boot} = app_child(Boot)
      control = Boot.status(control_boot)
      assert {:completed, ^control_worker} = control.reconciliation
      assert control.report.panes == []
      assert control.report.issues == [], "a healthy empty boot reports no issue"
    end
  end

  # =========================================================================
  # What deliberately does NOT fail the boot
  # =========================================================================

  describe "what does not fail the boot" do
    test "an absent or malformed :project_binding boots and serves, refusing every recorded pane" do
      inbox = inbox_root!()
      {wrapper_dir, log} = refusing_tmux_on_path!()
      sock_path = Path.join(inbox, "sock/ai-pair.sock")

      full_app_env!(inbox, wrapper_dir, fn ->
        Application.put_env(:ai_pair, :durable_attachments, true)
        Application.delete_env(:ai_pair, :tmux_server)
        Application.delete_env(:ai_pair, :boot_generation)
        Application.delete_env(:ai_pair, :pane_intent_store_fs)
        Application.delete_env(:ai_pair, :pane_intent_store_module)
        Application.delete_env(:ai_pair, :project_binding)
        refused_path_control!(log)
      end)

      assert {:ok, _} = start_app!()
      assert child_ids() == @durable_child_ids
      assert %{"ok" => true, "pong" => _} = ping!(sock_path)

      assert {:ok, boot} = app_child(Boot)
      absent = Boot.status(boot)
      assert {:completed, _} = absent.reconciliation

      assert {:config_invalid, :binding} in absent.report.issues,
             "an unusable binding must be reported, got: #{inspect(absent.report.issues)}"

      # A three-key map with a bad field is the same non-fatal outcome, located.
      stop_app!()

      Application.put_env(:ai_pair, :project_binding, %{
        project: "synthetic-project",
        project_dir: "relative",
        project_inbox: inbox
      })

      assert {:ok, _} = start_app!()
      assert {:ok, malformed_boot} = app_child(Boot)
      malformed = Boot.status(malformed_boot)

      assert {:config_invalid, :project_dir} in malformed.report.issues,
             "a located binding defect must be reported, got: #{inspect(malformed.report.issues)}"
    end

    test "an unreachable :tmux_server boots with an unobserved census" do
      inbox = inbox_root!()
      {wrapper_dir, log} = refusing_tmux_on_path!()

      full_app_env!(inbox, wrapper_dir, fn ->
        Application.put_env(:ai_pair, :durable_attachments, true)
        Application.delete_env(:ai_pair, :boot_generation)
        Application.delete_env(:ai_pair, :pane_intent_store_fs)
        Application.delete_env(:ai_pair, :pane_intent_store_module)
        Application.put_env(:ai_pair, :project_binding, binding_for(inbox))
        Application.put_env(:ai_pair, :tmux_server, :no_such_tmux_adapter_for_s10)
        refused_path_control!(log)
      end)

      assert {:ok, _} = start_app!()

      assert {:ok, boot} = app_child(Boot)
      status = Boot.status(boot)
      assert {:completed, _} = status.reconciliation

      assert {:source_unavailable, :live} in status.report.issues,
             "an unreachable adapter must be reported as an unavailable live source, " <>
               "got: #{inspect(status.report.issues)}"

      assert status.report.marker_observation == :unobserved

      # The default `{AiPair.Tmux, []}` child is STILL started and simply unused
      # by the durable path, which is what the contract states and what the
      # refused-route control below depends on.
      assert is_pid(Process.whereis(AiPair.Tmux))
      refused_app_adapter_control!(log, marker_set_attempts(log))
    end

    test "a boot report that cannot be written is a disposition, not a boot failure" do
      inbox = inbox_root!()
      {wrapper_dir, log} = refusing_tmux_on_path!()

      full_app_env!(inbox, wrapper_dir, fn ->
        Application.put_env(:ai_pair, :durable_attachments, true)
        Application.delete_env(:ai_pair, :tmux_server)
        Application.delete_env(:ai_pair, :boot_generation)
        Application.delete_env(:ai_pair, :pane_intent_store_fs)
        Application.delete_env(:ai_pair, :pane_intent_store_module)
        Application.put_env(:ai_pair, :project_binding, binding_for(inbox))
        refused_path_control!(log)
      end)

      # The report path is occupied by a DIRECTORY, so the writer's final
      # `File.rename/2` cannot land. No lib seam and no writer override: the
      # contract promises no `:report_writer` key, so the failure is induced
      # where the production writer really publishes.
      File.mkdir_p!(Boot.report_path(inbox))

      assert {:ok, _} = start_app!()

      assert {:ok, boot} = app_child(Boot)
      status = Boot.status(boot)
      assert {:completed, _} = status.reconciliation
      assert match?({:error, _}, status.report_write)
      assert status.report.panes == []

      # ... and the daemon serves.
      assert %{"ok" => true, "pong" => _} = ping!(Path.join(inbox, "sock/ai-pair.sock"))
      assert File.dir?(Boot.report_path(inbox)), "the occupied path must be left as it was"
    end
  end

  # =========================================================================
  # The contract's two substantive open questions
  # =========================================================================

  describe "contradictory configurations" do
    test "OQ-1 a binding whose project_inbox is not the resolved inbox is loud, and asymmetric" do
      inbox = inbox_root!()
      other = inbox_root!()
      {wrapper_dir, log} = refusing_tmux_on_path!()

      full_app_env!(inbox, wrapper_dir, fn ->
        Application.put_env(:ai_pair, :durable_attachments, true)
        Application.delete_env(:ai_pair, :tmux_server)
        Application.delete_env(:ai_pair, :boot_generation)
        Application.delete_env(:ai_pair, :pane_intent_store_fs)
        Application.delete_env(:ai_pair, :pane_intent_store_module)
        Application.put_env(:ai_pair, :project_binding, binding_for(other))
        refused_path_control!(log)
      end)

      logged = capture_log(fn -> assert {:ok, _} = start_app!() end)

      # The contract does not authorise failing the boot closed here, so the
      # divergence is reported instead: the message names BOTH roots, so an
      # operator reading a `durable_unavailable` reply can find the cause.
      assert logged =~ "project_binding.project_inbox"
      assert logged =~ Path.expand(other)
      assert logged =~ Path.expand(inbox)

      # And the asymmetry itself, measured rather than described: the store owns
      # the INBOX key, which is what boot reconciliation holds and why it worked,
      # while the key durable attach resolves - the BINDING's - has no owner at
      # all, which is why every durable attach answers `durable_unavailable`.
      assert is_pid(:global.whereis_name({PaneIntentStore, Path.expand(inbox)}))

      assert :undefined == :global.whereis_name({PaneIntentStore, Path.expand(other)}),
             "nothing may own the binding's key; that disagreement IS the finding"

      assert {:ok, boot} = app_child(Boot)
      status = Boot.status(boot)
      assert {:completed, _} = status.reconciliation
      assert status.report.root == inbox

      refute Enum.any?(status.report.issues, &match?({:config_invalid, _}, &1)),
             "the binding is well formed, so reconciliation must not report it as invalid; " <>
               "that is exactly why the divergence is silent without the warning above"

      # CONTROL: with the binding agreeing, the same boot logs nothing.
      stop_app!()
      Application.put_env(:ai_pair, :project_binding, binding_for(inbox))
      agreed = capture_log(fn -> assert {:ok, _} = start_app!() end)

      refute agreed =~ "project_binding.project_inbox",
             "the warning fired on an agreeing binding; it does not measure the divergence"
    end

    test "OQ-2 an unregistered :pane_intent_store_module boots, and surfaces only in the report" do
      inbox = inbox_root!()
      {wrapper_dir, log} = refusing_tmux_on_path!()

      full_app_env!(inbox, wrapper_dir, fn ->
        Application.put_env(:ai_pair, :durable_attachments, true)
        Application.delete_env(:ai_pair, :tmux_server)
        Application.delete_env(:ai_pair, :boot_generation)
        Application.delete_env(:ai_pair, :pane_intent_store_fs)
        Application.put_env(:ai_pair, :pane_intent_store_module, UnregisteredStore)
        Application.put_env(:ai_pair, :project_binding, binding_for(inbox))
        refused_path_control!(log)
      end)

      assert {:ok, _} = start_app!()

      # The child STARTED - it is there under the store's own id, because only
      # `:start` was substituted - and the boot succeeded.
      assert {:ok, store_child} = app_child(PaneIntentStore)
      assert is_pid(store_child)
      assert child_ids() == @durable_child_ids

      # ... but it claimed no `:global` key, so `Boot`'s snapshot `:list` exited
      # `:noproc` and the daemon came up having reconciled nothing while every
      # record would sit on disk. This is the whole of OQ-2: the defect is real,
      # it is not silent, and it surfaces LATE rather than at boot.
      assert :undefined == :global.whereis_name({PaneIntentStore, Path.expand(inbox)})

      assert {:ok, boot} = app_child(Boot)
      status = Boot.status(boot)

      assert {:source_unavailable, :intent} in status.report.issues,
             "an unregistered store module must surface as an unavailable intent source, " <>
               "got: #{inspect(status.report.issues)}"

      assert status.report.panes == []
      assert %{"ok" => true, "pong" => _} = ping!(Path.join(inbox, "sock/ai-pair.sock"))
    end
  end

  # =========================================================================
  # Legacy is unchanged (B1's full-application half, which S11 could not carry)
  # =========================================================================

  describe "legacy is unchanged" do
    test "B1 a legacy boot starts the eight children and nothing durable, with zero marker writes" do
      inbox = inbox_root!()
      {wrapper_dir, log} = refusing_tmux_on_path!()

      # The marker-write witness is EXTERNAL: the wrapper first on PATH records
      # every `tmux` argv the application resolves, and the calibration control
      # proves the counter is live BEFORE the boot it counts, so a blind counter
      # fails here rather than silently reading zero.
      baseline =
        full_app_env!(inbox, wrapper_dir, fn ->
          Application.delete_env(:ai_pair, :durable_attachments)
          Application.delete_env(:ai_pair, :tmux_server)
          refused_path_control!(log)
        end)

      assert {:ok, _} = start_app!()

      assert child_ids() == @legacy_child_ids, "legacy boot child list changed"

      assert :undefined == :global.whereis_name({PaneIntentStore, Path.expand(inbox)}),
             "legacy boot must not start the pane-intent store"

      assert Process.whereis(Boot) == nil, "legacy boot must not start Boot"
      assert Process.whereis(Coordinator) == nil, "legacy boot must not start the Coordinator"

      assert marker_set_attempts(log) == baseline,
             "a legacy boot attempted a marker write: #{inspect(wrapper_lines(log))}"

      refused_app_adapter_control!(log, baseline)

      refute File.exists?(Boot.report_path(inbox)), "legacy boot must not write a boot report"
    end

    test "the five durable-only keys are not even read when :durable_attachments is unset" do
      inbox = inbox_root!()
      {wrapper_dir, log} = refusing_tmux_on_path!()
      me = self()

      # Every seam a durable boot would consume is configured to something a
      # durable boot could not survive or could not miss: a generation that
      # fails the decimal check, a store module that reports every `:list`, and
      # an adapter name nothing answers. A legacy boot reads none of them.
      full_app_env!(inbox, wrapper_dir, fn ->
        Application.delete_env(:ai_pair, :durable_attachments)
        Application.put_env(:ai_pair, :boot_generation, "not-a-decimal")
        Application.put_env(:ai_pair, :pane_intent_store_module, ControlledStore)
        Application.put_env(:ai_pair, :application_durable_boot_store, test: me, records: [])
        Application.put_env(:ai_pair, :pane_intent_store_fs, {:not, :a, :handle})
        Application.put_env(:ai_pair, :project_binding, binding_for(inbox))
        Application.put_env(:ai_pair, :tmux_server, :no_such_tmux_adapter_for_s10)
        refused_path_control!(log)
      end)

      assert {:ok, _} = start_app!()
      assert child_ids() == @legacy_child_ids
      refute_receive {:store_list, _, _, _}, 200
      refute File.exists?(Boot.report_path(inbox))
    end

    test "only the literal true is durable: false, nil, a string and an integer are all legacy" do
      inbox = inbox_root!()
      {wrapper_dir, log} = refusing_tmux_on_path!()

      full_app_env!(inbox, wrapper_dir, fn ->
        Application.delete_env(:ai_pair, :tmux_server)
        Application.delete_env(:ai_pair, :boot_generation)
        Application.delete_env(:ai_pair, :pane_intent_store_fs)
        Application.delete_env(:ai_pair, :pane_intent_store_module)
        Application.put_env(:ai_pair, :project_binding, binding_for(inbox))
        refused_path_control!(log)
      end)

      for value <- [false, nil, "true", 1, :true_atom_lookalike, [true]] do
        stop_app!()
        Application.put_env(:ai_pair, :durable_attachments, value)

        assert {:ok, _} = start_app!(),
               "durable_attachments #{inspect(value)} must be legacy, and legacy is not an error"

        assert child_ids() == @legacy_child_ids,
               "durable_attachments #{inspect(value)} was treated as durable"

        assert Process.whereis(Coordinator) == nil
      end

      # And the control, under the same snapshot: the literal `true` IS durable,
      # so the loop above discriminates the value and not the fixture.
      stop_app!()
      Application.put_env(:ai_pair, :durable_attachments, true)
      assert {:ok, _} = start_app!()
      assert child_ids() == @durable_child_ids
    end
  end

  # =========================================================================
  # NS-15.G.001: restart with a dead/stale/live intent mix
  # =========================================================================
  #
  # Register row NS-15.G.001. Acceptance: "Restart with dead/stale/live intent
  # mix". Failure control: "Deleting stale record merely on boot fails".
  #
  # SCOPE, stated so it is not read as more: the restart here is SOURCE-LEVEL -
  # the actual `:ai_pair` application stopped (its supervisor's DOWN joined) and
  # started again inside this BEAM. It is not an OS-process restart, not a
  # release or installed-daemon restart, and it does not survive a VM exit.
  #
  # The records are seeded through the REAL `PaneIntentStore.put/2` of the first
  # boot and persisted by it; the second boot reads them back from disk. The
  # first boot's `:tmux_server` names no process, so it takes no census and
  # consumes no scripted step (asserted). The second boot's `:tmux_server` is a
  # `ScriptedTmux` adapter (Bash stub, no tmux server) scripted for exactly the
  # reconciliation's reads: census, the one census session's marker, then the
  # live pane's fenced census and marker re-read. Records, census rows and the
  # marker are lined up as in `reconciler_test.exs`'s unit row for the same
  # acceptance, so only the intended field differs per record.
  #
  # KNOWN BEHAVIOUR, handled rather than hidden: the quarantined live pane polls
  # its capture through the same adapter every 250 ms, and every capture past
  # the script is the stub's unscripted `exit 99`. So no total call count is
  # asserted; the four scripted steps are asserted by position, every recorded
  # argv is checked for option writes, and the row proves a failed capture does
  # not crash the pane (same pid, still alive, still quarantined).
  describe "NS-15.G.001 restart with a dead/stale/live intent mix" do
    test "a restart refuses dead and stale records, retains their bytes, and starts only the live pane" do
      inbox = inbox_root!()
      {wrapper_dir, log} = refusing_tmux_on_path!()
      generation = decimal_generation()

      [live, dead, stale_pid, stale_gen] =
        for _ <- 1..4, do: "%" <> Integer.to_string(System.unique_integer([:positive]))

      records = [
        restart_record(live, inbox, generation),
        restart_record(dead, inbox, generation),
        restart_record(stale_pid, inbox, generation),
        restart_record(stale_gen, inbox, "8")
      ]

      census =
        {restart_census_row(live, inbox) <>
           restart_census_row(stale_pid, inbox, "4343") <>
           restart_census_row(stale_gen, inbox), 0}

      marker =
        {Jason.encode!(%{
           "version" => 1,
           "owner_root" => inbox,
           "session_id" => "$3",
           "generation" => generation
         }) <> "\n", 0}

      # Started before either boot so the first boot's zero use of it is measured.
      {scripted, scripted_dir} = ScriptedTmux.start!([census, marker, census, marker])

      baseline =
        full_app_env!(inbox, wrapper_dir, fn ->
          Application.put_env(:ai_pair, :durable_attachments, true)
          Application.delete_env(:ai_pair, :boot_generation)
          Application.delete_env(:ai_pair, :pane_intent_store_fs)
          Application.delete_env(:ai_pair, :pane_intent_store_module)
          Application.put_env(:ai_pair, :project_binding, binding_for(inbox))
          Application.put_env(:ai_pair, :tmux_server, :no_such_tmux_adapter_for_ns15)
          refused_path_control!(log)
        end)

      # ---- (1) first boot, absent adapter; seed through the real store --------
      assert {:ok, _} = start_app!()
      store = :global.whereis_name({PaneIntentStore, Path.expand(inbox)})
      assert is_pid(store)

      for record <- records, do: assert(:ok = PaneIntentStore.put(store, record))
      assert {:ok, listed} = PaneIntentStore.list(store)
      assert Enum.map(listed, & &1["pane_id"]) == Enum.sort([live, dead, stale_pid, stale_gen])

      assert ScriptedTmux.calls!(scripted_dir) == 0,
             "the first boot must not consume a scripted tmux step"

      # ---- (2) the exact bytes, then a proven stop ----------------------------
      state_file = Path.join([inbox, "state", "pane-attachments.json"])
      seeded_bytes = File.read!(state_file)
      stop_app!()

      assert Process.whereis(AiPair.Supervisor) == nil
      assert :global.whereis_name({PaneIntentStore, Path.expand(inbox)}) == :undefined
      refute Process.alive?(store)
      assert File.read!(state_file) == seeded_bytes, "stopping must not rewrite the records"

      # ---- (3) restart against the scripted adapter ---------------------------
      Application.put_env(:ai_pair, :tmux_server, scripted)
      assert {:ok, _} = start_app!()

      assert {:ok, boot} = app_child(Boot)
      status = Boot.status(boot)
      assert {:completed, _worker} = status.reconciliation
      report = status.report

      # ---- (4) each record's status and refusal -------------------------------
      row = fn pane -> Enum.find(report.panes, &(&1.pane_id == pane)) end
      assert length(report.panes) == 4

      assert %{status: :observed_quarantined, refusals: [], dispatchable: false} = row.(live)

      assert %{status: :refused, refusals: [{:live_absent}, {:source_unavailable, :marker}]} =
               row.(dead)

      assert %{status: :refused, refusals: [{:conflicting, :live}]} = row.(stale_pid)
      assert %{status: :refused, refusals: [{:generation_mismatch}]} = row.(stale_gen)

      assert Enum.sort(report.issues) ==
               Enum.sort([
                 {:source_unavailable, :marker},
                 {:live_absent, dead},
                 {:conflicting, :live, stale_pid},
                 {:generation_mismatch, stale_gen}
               ])

      assert report.marker_writes == 0

      # Only the live pane has a child.
      assert {:ok, sm} = AiPair.PaneSupervisor.whereis_pane(live)

      for pane <- [dead, stale_pid, stale_gen],
          do: assert(:error == AiPair.PaneSupervisor.whereis_pane(pane))

      # Every record retained, byte for byte: nothing was deleted merely on boot.
      assert File.read!(state_file) == seeded_bytes,
             "the restart rewrote the intent file; a refused record must be retained"

      restarted = :global.whereis_name({PaneIntentStore, Path.expand(inbox)})
      assert {:ok, ^listed} = PaneIntentStore.list(restarted)

      # The four scripted reads, by position; the quarantined pane's later
      # captures are unscripted and not counted.
      assert eventually?(fn -> ScriptedTmux.calls!(scripted_dir) >= 5 end),
             "the quarantined pane never polled a capture through the adapter"

      [c1, m1, c2, m2 | captures] = ScriptedTmux.argvs!(scripted_dir)
      for argv <- [c1, c2], do: assert("list-panes" in argv)
      for argv <- [m1, m2], do: assert("show-options" in argv and "$3" in argv)
      assert captures != [] and Enum.all?(captures, &("capture-pane" in &1))

      # No option write reached tmux: not through the scripted adapter, and not
      # through the refusing wrapper on PATH.
      refute Enum.any?(ScriptedTmux.argvs!(scripted_dir), fn argv ->
               Enum.any?(argv, &(&1 in ["set", "set-option", "setw", "set-window-option"]))
             end)

      assert marker_set_attempts(log) == baseline

      # A failed (unscripted, exit 99) capture does not crash the pane.
      assert Process.alive?(sm)
      assert {:ok, ^sm} = AiPair.PaneSupervisor.whereis_pane(live)
      assert AiPair.Pane.StateMachine.status(sm).quarantined == true

      # ---- (5) control: a real deletion does change the bytes -----------------
      assert :ok = PaneIntentStore.delete(restarted, stale_pid)

      refute File.read!(state_file) == seeded_bytes,
             "the byte comparison must detect a deleted record, or the retention check is blind"

      # Stopped here, while the scripted adapter still runs, so the polling pane
      # never outlives its adapter.
      stop_app!()
    end
  end

  defp restart_record(pane, root, generation) do
    %{
      "schema_version" => "1.0",
      "pane_id" => pane,
      "agent" => "synthetic-agent",
      "classifier" => "stub",
      "project" => "synthetic-project",
      "project_dir" => root,
      "project_inbox" => root,
      "tmux_session" => "restore-fixture",
      "session_gen" => generation,
      "cwd" => root,
      "command" => "zsh",
      "pane_pid" => 4242,
      "updated_at" => "2026-09-25T00:00:00Z"
    }
  end

  # One raw row of the frozen strict-census format, session `$3`.
  defp restart_census_row(pane, root, pid \\ "4242"),
    do: "#{pane}|$3|restore-fixture|0|0|#{pid}|zsh|#{root}\n"

  defp eventually?(fun, deadline_ms \\ 2_000) do
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

  # ===== the full-application fixture ======================================
  #
  # Carried from the reviewed RED's `full_app_env!/3` (AMEND M1/M6). EVERY key
  # and variable a full-app row mutates is snapshotted here and restored - in
  # the teardown, AFTER the fixture application is stopped (its tree joined) and
  # BEFORE the prior application is restarted - so the restored daemon never
  # boots against a fixture binding whose directory is about to be removed. A
  # key that had a value is put back; only a key that was absent is deleted.
  # Callers therefore never register their own `delete_env` teardown for these.
  #
  # The stale telemetry handler is detached across the stop because
  # `OtelBridge.init` attaches a NAMED `:telemetry` handler that a plain stop
  # does not clear, and a restart would then fail `{:error, :already_exists}`.
  #
  # The refusing `tmux` wrapper is put FIRST on PATH before the application
  # starts and taken off only here, after `Application.stop/1` has joined the
  # supervision tree; a worker that outlived its supervisor would still resolve
  # `tmux` to the wrapper until then. `env_fun` runs in that window (PATH bound,
  # nothing serving) and its value is returned so a row can calibrate its
  # counter there. The row then calls `start_app!/0` (and `stop_app!/0` between
  # phases) itself, because a row may boot the fixture application more than
  # once under ONE snapshot - which is what a positive control beside a faulted
  # boot needs.

  @full_app_keys [
    :durable_attachments,
    :project_binding,
    :inbox,
    :tmux_server,
    :pane_intent_store_fs,
    :pane_intent_store_module,
    :boot_generation,
    :application_durable_boot_store
  ]
  @full_app_vars ["AI_PAIR_INBOX", "PATH"]

  defp full_app_env!(inbox, wrapper_dir, env_fun) do
    prior_vars = Map.new(@full_app_vars, &{&1, System.get_env(&1)})
    prior_keys = Map.new(@full_app_keys, &{&1, Application.fetch_env(:ai_pair, &1)})

    # M6: restoration of PATH, the keys and the prior application is CONDITIONAL
    # on proven containment. `stop_app!/0` raises unless the fixture
    # application's stop result is classified `:ok` or not-started AND its
    # supervisor's DOWN was joined; on a raise this callback aborts before
    # restoring anything, so the refusing wrapper stays first on PATH, no real
    # adapter route is restored, and the wrapper directory is retained.
    on_exit(fn ->
      stop_app!()
      File.write!(Path.join(wrapper_dir, "CONTAINED"), "stop joined\n")
      restore_vars!(prior_vars)
      restore_keys!(prior_keys)
      {:ok, _} = Application.ensure_all_started(:ai_pair)
    end)

    stop_app!()
    System.put_env("AI_PAIR_INBOX", inbox)
    System.put_env("PATH", wrapper_dir <> ":" <> (prior_vars["PATH"] || ""))
    env_fun.()
  end

  defp start_app!, do: Application.ensure_all_started(:ai_pair)

  # Stop and PROVE the stop (M6). The exact stop outcome is classified: `:ok`,
  # or the specific not-started error (a failed-closed boot left nothing to
  # stop); anything else raises. When a supervisor was running, its DOWN is
  # joined with a bound, so "stopped" is an observed fact and not a call that
  # returned.
  defp stop_app! do
    sup = Process.whereis(AiPair.Supervisor)
    ref = if is_pid(sup), do: Process.monitor(sup)

    case Application.stop(:ai_pair) do
      :ok ->
        :ok

      {:error, {:not_started, :ai_pair}} ->
        :ok

      other ->
        raise "Application.stop(:ai_pair) returned #{inspect(other)}; fixture shutdown unproven"
    end

    if ref do
      receive do
        {:DOWN, ^ref, :process, ^sup, _} -> :ok
      after
        5_000 -> raise "AiPair.Supervisor #{inspect(sup)} did not terminate; containment unproven"
      end
    end

    :telemetry.detach(AiPair.Telemetry.OtelBridge)
    :ok
  end

  defp restore_vars!(prior) do
    Enum.each(prior, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end

  defp restore_keys!(prior) do
    Enum.each(prior, fn
      {key, {:ok, value}} -> Application.put_env(:ai_pair, key, value)
      {key, :error} -> Application.delete_env(:ai_pair, key)
    end)
  end

  # The fixture application's own children by id, once startup has finished.
  defp app_child(id) do
    case List.keyfind(Supervisor.which_children(AiPair.Supervisor), id, 0) do
      {^id, pid, _type, _mods} when is_pid(pid) -> {:ok, pid}
      _ -> :error
    end
  end

  defp child_ids do
    AiPair.Supervisor
    |> Supervisor.which_children()
    |> Enum.map(fn {id, _pid, _type, _mods} -> id end)
  end

  # A live listener, not a pathname: `{:ok, _}` means something ACCEPTS there;
  # `{:error, _}` means nothing serves, whatever file may or may not exist.
  defp listener_alive?(sock_path) do
    case :gen_tcp.connect({:local, sock_path}, 0, [:binary, {:active, false}], 500) do
      {:ok, port} ->
        :gen_tcp.close(port)
        true

      {:error, _} ->
        false
    end
  end

  defp ping!(sock_path) do
    {:ok, client} =
      :gen_tcp.connect({:local, sock_path}, 0, [:binary, {:active, false}, {:packet, 4}], 1_000)

    :ok = :gen_tcp.send(client, ~s({"cmd":"ping"}))
    {:ok, frame} = :gen_tcp.recv(client, 0, 1_000)
    :gen_tcp.close(client)
    Jason.decode!(frame)
  end

  # The starter task is killed and joined at teardown whatever the row did, so a
  # row that fails while the store is held leaves no task behind.
  defp own_task!(%Task{pid: pid}) do
    on_exit(fn ->
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        5_000 -> raise "starter task #{inspect(pid)} did not terminate; cleanup unwitnessed"
      end
    end)
  end

  defp binding_for(root) do
    %{project: "synthetic-project", project_dir: root, project_inbox: root}
  end

  defp decimal_generation,
    do: Integer.to_string(:binary.decode_unsigned(:crypto.strong_rand_bytes(8)))

  # Every subdirectory `AiPair.Inbox.resolve!/0` will create is created HERE at
  # 0700 first, because `mkdir_p` leaves an existing directory's mode alone and
  # `resolve!/0` chmods only `sock`. The pane-intent store refuses to start
  # against a `state` directory that is group- or world-readable
  # (`pane_intent_store.ex:327-343`, `{:unsafe_mode, _}` at stage `:permission`),
  # which is a real product rule and not something a fixture may route around.
  @inbox_subdirs ~w(sock fingerprints logs state inbox outbox processed)

  defp inbox_root! do
    inbox = Path.join(canonical_tmp(), "ai_pair_s10_inbox_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(inbox) end)
    File.mkdir_p!(inbox)
    File.chmod!(inbox, 0o700)

    for name <- @inbox_subdirs do
      sub = Path.join(inbox, name)
      File.mkdir_p!(sub)
      File.chmod!(sub, 0o700)
    end

    inbox
  end

  defp canonical_tmp do
    System.tmp_dir!()
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce("/", fn seg, acc ->
      joined = Path.join(acc, seg)

      case File.read_link(joined) do
        {:ok, "/" <> _ = absolute} -> absolute
        {:ok, relative} -> Path.expand(Path.join(Path.dirname(joined), relative))
        {:error, _} -> joined
      end
    end)
  end

  # ===== the PATH boundary =================================================
  #
  # The fixture-owned `tmux` for full-application rows. Bash; never execs the
  # real binary. Every invocation appends `ARGV <args>` and `RC <status> <args>`
  # to the log (fail-closed on the append, exit 90). The tmux subcommand is the
  # first non-option argument after `-L/-S/-f <x>`:
  #   list-panes    -> empty stdout, exit 0   (an empty server: a boot may census)
  #   show-options  -> "invalid option" on stderr, exit 1 (the ABSENT-marker
  #                    spelling `marker.ex` recognises; nothing is invented)
  #   anything else -> refused, exit 97, nothing performed.
  #
  # LIMIT, stated because it must not be mistaken for more: this binds ONLY the
  # `tmux` that `tmux.ex` resolves from PATH. It is not a process sandbox. A
  # spawn by absolute path, an `:os.cmd`, or any executable other than `tmux` is
  # not intercepted. The refused-route controls prove the application's adapter
  # child reaches THIS wrapper; they prove nothing about routes the wrapper
  # cannot see.

  defp refusing_tmux_on_path! do
    dir = Path.join(canonical_tmp(), "tmux_refuse_s10_#{System.unique_integer([:positive])}")

    # M6: removed only when `full_app_env!/3`'s teardown proved containment (it
    # writes CONTAINED after a joined stop). Otherwise the refusing wrapper is
    # RETAINED on disk and this callback raises, so a failed containment cannot
    # lose its boundary to a later cleanup.
    on_exit(fn ->
      if File.exists?(Path.join(dir, "CONTAINED")) do
        File.rm_rf!(dir)
      else
        raise "containment unproven; refusing tmux wrapper retained at #{dir}"
      end
    end)

    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    log = Path.join(dir, "argv.log")
    bin = Path.join(dir, "tmux")

    refute String.contains?(log, "'"),
           "path #{log} contains a single quote; the wrapper cannot safely quote it"

    File.write!(bin, """
    #!/usr/bin/env bash
    argv="$*"
    printf 'ARGV %s\\n' "$argv" >> '#{log}' || exit 90
    cmd=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -L|-S|-f) shift 2 ;;
        -*) shift ;;
        *) cmd="$1"; break ;;
      esac
    done
    case "$cmd" in
      list-panes)
        printf 'RC 0 %s\\n' "$argv" >> '#{log}' || exit 90
        exit 0 ;;
      show-options)
        printf 'RC 1 %s\\n' "$argv" >> '#{log}' || exit 90
        printf 'invalid option: fixture empty server\\n' >&2
        exit 1 ;;
      *)
        printf 'RC #{@wrapper_refusal_status} %s\\n' "$argv" >> '#{log}' || exit 90
        printf 'fixture tmux boundary refused: %s\\n' "$argv" >&2
        exit #{@wrapper_refusal_status} ;;
    esac
    """)

    File.chmod!(bin, 0o700)
    {dir, log}
  end

  # Refused-default-route CONTROL, half one: resolving the bare `tmux` from PATH
  # exactly as `tmux.ex` does must reach the wrapper and be refused with the
  # wrapper's OWN exit status. The target is a session that cannot exist, so if
  # the real binary were reached the command would fail harmlessly with tmux's
  # exit 1 - and this assertion would fail on the status. Returns the resulting
  # marker-write attempt count, the `baseline >= 1` the counter is calibrated by.
  defp refused_path_control!(log) do
    {_out, status} =
      System.cmd(
        "tmux",
        ["set-option", "-t", "$fixture-unreachable", @marker_option, "control"],
        stderr_to_stdout: true
      )

    assert status == @wrapper_refusal_status,
           "PATH did not resolve `tmux` to the refusing wrapper (exit #{status}); no boundary"

    baseline = marker_set_attempts(log)
    assert baseline >= 1, "the wrapper never recorded the control write; the counter is blind"
    baseline
  end

  # Refused-default-route CONTROL, half two: a mutating call through the
  # APPLICATION'S OWN `{AiPair.Tmux, []}` child (the default registered name,
  # nothing substituted) must reach the wrapper and be refused with its status,
  # and must show up in the log as exactly one more marker-write attempt.
  defp refused_app_adapter_control!(log, attempts_before) do
    assert {:error, %{status: @wrapper_refusal_status}} =
             Tmux.set_option("$fixture-unreachable", @marker_option, "control", AiPair.Tmux),
           "the application's own tmux adapter did not route to the refusing wrapper"

    assert marker_set_attempts(log) == attempts_before + 1,
           "the application adapter's refused write was not recorded by the wrapper"
  end

  defp wrapper_lines(log) do
    case File.read(log) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, reason} -> raise "wrapper log #{log} unreadable (#{inspect(reason)}); not evidence"
    end
  end

  # Marker-option `set-option` argv, counted independently of any field the
  # product reports. tmux accepts `set` and `set-option`; reads (`show`) are
  # excluded so a boot that merely READS a marker is not counted as a write.
  defp marker_set_attempts(log) do
    Enum.count(wrapper_lines(log), fn line ->
      String.starts_with?(line, "ARGV ") and marker_set_argv?(line)
    end)
  end

  defp marker_set_argv?(line) do
    words = String.split(line)

    String.contains?(line, @marker_option) and
      Enum.any?(words, &(&1 in ["set", "set-option", "setw", "set-window-option"])) and
      not Enum.any?(words, &String.starts_with?(&1, "show"))
  end
end
