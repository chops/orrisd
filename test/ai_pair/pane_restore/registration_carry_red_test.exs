defmodule AiPair.PaneRestore.RegistrationCarryRedTest do
  # NS-15.G.002 B1a-1 RED (scope r3): boot admission and re-admission CARRY a pane's registration and
  # never mint one.
  #
  #   * an admitted 2.0 intent row recording reg_<32 hex> starts a child serving exactly that id, visible
  #     through StateMachine.get_info/1 and, without calling the child, PaneSupervisor.registration/1;
  #   * a row recording null, and a 1.0 row, start a child serving nil;
  #   * a row whose registration_id is malformed is refused: no child;
  #   * Reconciler.readmit/2 starts the replacement serving exactly the old child's id (nil stays nil).
  #
  # Fakes and helpers are trimmed copies of restore_reconciler_red_test.exs; the fence is the real
  # Coordinator, the child is started through the real PaneSupervisor, and paste_fn records nothing.
  use ExUnit.Case, async: false

  alias AiPair.Delivery.{Payload, ReceiptStore, SystemFs}
  alias AiPair.Pane.StateMachine
  alias AiPair.PaneRestore.{Coordinator, Reconciler}
  alias AiPair.PaneSupervisor

  @root "/synthetic/inbox"
  @generation "213598703592091008239502170616955211460"
  @binding %{project: "synthetic-project", project_dir: @root, project_inbox: @root}
  @reg "reg_" <> String.duplicate("5a", 16)

  defmodule FakeStore do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    @impl true
    def init(opts), do: {:ok, %{lists: Keyword.fetch!(opts, :lists)}}
    @impl true
    def handle_call(:list, _from, %{lists: [reply | rest]} = s),
      do: {:reply, reply, %{s | lists: rest}}

    def handle_call(:list, _from, %{lists: []} = s), do: {:stop, :unscripted_list, s}

    def handle_call(request, _from, _s),
      do: raise("no intent write expected, got #{inspect(request)}")
  end

  defmodule FakeTmux do
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    @impl true
    def init(opts),
      do: {:ok, %{observe: Keyword.fetch!(opts, :observe), show: Keyword.fetch!(opts, :show)}}

    @impl true
    def handle_call(:observe_panes, _from, %{observe: [r | rest]} = s),
      do: {:reply, r, %{s | observe: rest}}

    def handle_call({:show_options, target, _option}, _from, s) do
      [r | rest] = Map.fetch!(s.show, target)
      {:reply, r, %{s | show: Map.put(s.show, target, rest)}}
    end

    def handle_call(request, _from, _s),
      do: raise("no tmux write expected, got #{inspect(request)}")
  end

  setup do
    inbox = Path.join(System.tmp_dir!(), "b1a_carry_#{System.unique_integer([:positive])}")
    File.mkdir_p!(inbox)
    on_exit(fn -> File.rm_rf!(inbox) end)
    start_supervised!({Coordinator, [name: Coordinator]}, restart: :temporary)
    {:ok, inbox: inbox}
  end

  test "K1 an admitted row recording a registration starts a child serving exactly that id" do
    pane = pane_id()
    own_pane(pane)
    {agent, callbacks} = recorder()

    report = reconcile(record_v2(pane, @reg), pane, callbacks, [])

    assert [%{status: :observed_quarantined}] = report.panes
    assert {:ok, sm} = PaneSupervisor.whereis_pane(pane)
    assert StateMachine.get_info(sm).registration_id == @reg
    assert registration(pane) == {:ok, @reg}
    assert Agent.get(agent, & &1.pastes) == []
  end

  test "K2 a row recording null, and a 1.0 row, start a child serving no registration" do
    for row_for <- [&record_v2(&1, nil), &record_v1/1] do
      pane = pane_id()
      own_pane(pane)
      {agent, callbacks} = recorder()

      report = reconcile(row_for.(pane), pane, callbacks, [])

      assert [%{status: :observed_quarantined}] = report.panes
      assert {:ok, sm} = PaneSupervisor.whereis_pane(pane)
      assert StateMachine.get_info(sm).registration_id == nil
      assert registration(pane) == {:ok, nil}
      assert Agent.get(agent, & &1.pastes) == []
    end
  end

  test "K3 a row whose registration id is malformed is refused and starts no child" do
    for bad <- ["reg_" <> String.duplicate("A", 32), "reg_short", 7] do
      pane = pane_id()
      own_pane(pane)
      {_agent, callbacks} = recorder()

      report = reconcile(record_v2(pane, bad), pane, callbacks, [])

      refute Enum.any?(report.panes, &(&1[:status] == :observed_quarantined)), inspect(bad)
      assert PaneSupervisor.whereis_pane(pane) == :error, inspect(bad)
    end
  end

  test "K4 re-admission starts the replacement serving the old child's exact registration", c do
    for carried <- [@reg, nil] do
      pane = pane_id()
      own_pane(pane)
      rstore = restored_store!(c.inbox, pane, "k4-#{inspect(carried)}")
      {agent, callbacks} = recorder()
      _ = reconcile(record_v2(pane, carried), pane, callbacks, receipt_store: rstore)
      {:ok, old} = PaneSupervisor.whereis_pane(pane)

      assert {:ok, new} =
               Reconciler.readmit(pane, receipt_store: rstore, callbacks: callbacks)

      refute new == old
      assert StateMachine.get_info(new).registration_id == carried
      assert registration(pane) == {:ok, carried}
      assert Agent.get(agent, & &1.pastes) == []
    end
  end

  # --- helpers (trimmed copies of restore_reconciler_red_test.exs) ---------------------------

  defp restored_store!(inbox, pane, seed) do
    inbox = Path.join(inbox, seed)
    File.mkdir_p!(inbox)

    {:ok, first} =
      GenServer.start(ReceiptStore, inbox: inbox, fs: SystemFs.new(), restore_issuer: Coordinator)

    {:ok, {:admitted, %{operation_token: token}}} =
      ReceiptStore.admit(first, id(seed), pane, hash(seed <> " bytes"), self())

    :ok = ReceiptStore.queue(first, id(seed), token, seed <> " bytes")
    Process.exit(first, :kill)
    Process.sleep(20)

    {:ok, revived} =
      GenServer.start(ReceiptStore, inbox: inbox, fs: SystemFs.new(), restore_issuer: Coordinator)

    on_exit(fn -> if Process.alive?(revived), do: Process.exit(revived, :kill) end)
    revived
  end

  defp reconcile(row, pane, callbacks, overrides) do
    rows = [row]
    census = [observation(pane)]

    store =
      start_supervised!(%{
        id: {:fake_store, pane},
        start: {FakeStore, :start_link, [[lists: [{:ok, rows}, {:ok, rows}]]]},
        restart: :temporary
      })

    name = String.to_atom("fake_tmux_#{System.unique_integer([:positive])}")

    start_supervised!(%{
      id: name,
      start:
        {FakeTmux, :start_link,
         [
           [
             name: name,
             observe: [{:ok, census}, {:ok, census}],
             show: %{"$3" => [shown(), shown()]}
           ]
         ]},
      restart: :temporary
    })

    [store: store, root: @root, tmux: name, binding: @binding, callbacks: callbacks]
    |> Keyword.merge(overrides)
    |> Reconciler.reconcile()
  end

  defp recorder do
    {:ok, agent} = start_supervised({Agent, fn -> %{pastes: []} end}, id: make_ref())

    callbacks = %{
      capture_fn: fn _pane -> {:ok, "IDLE_MARKER"} end,
      paste_fn: fn pane, text ->
        Agent.update(agent, &%{&1 | pastes: [{pane, text} | &1.pastes]})
        :ok
      end
    }

    {agent, callbacks}
  end

  defp record_v1(pane) do
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
    }
  end

  defp record_v2(pane, registration_id),
    do:
      Map.merge(record_v1(pane), %{"schema_version" => "2.0", "registration_id" => registration_id})

  defp observation(pane) do
    %{
      pane_id: pane,
      session_id: "$3",
      session_name: "restore-fixture",
      window_index: 0,
      pane_index: 0,
      pane_pid: 4242,
      command: "zsh",
      path: @root
    }
  end

  defp shown do
    marker = %{
      "version" => 1,
      "owner_root" => @root,
      "session_id" => "$3",
      "generation" => @generation
    }

    {:ok, Jason.encode!(marker) <> "\n"}
  end

  # apply/3: the function is GREEN's (PaneSupervisor.registration/1), absent at the RED base.
  defp registration(pane), do: apply(PaneSupervisor, :registration, [pane])

  defp pane_id, do: "%" <> Integer.to_string(System.unique_integer([:positive]))
  defp own_pane(pane), do: on_exit(fn -> PaneSupervisor.stop_pane(pane) end)
  defp hash(text), do: Payload.hash(Payload.new(text))
  defp id(seed), do: "snd_" <> Base.encode16(:crypto.hash(:sha256, seed), case: :lower)
end
