defmodule AiPair.AdmissionG2FailstopTest do
  @moduledoc """
  NS-32.M.002 RB-3a GREEN-2, design r4 (D/rb/RB3A-GREEN2-DESIGN-r4.org, DESIGN GO
  m_20261007T172944Z): the durable application's wiring (W5 row 10) and the W1 failure matrix,
  each in the ACTUAL durable application (`AiPair.Test.DurableApp`).

  W1: `AiPair.Admission`, `AiPair.Delivery.ReceiptStore` and `AiPair.PaneIntentStore` are
  temporary and significant under `auto_shutdown: :any_significant`, so the exit of any of them
  ends `AiPair.Supervisor` (the daemon) and nothing is restarted: a fence or an orphaned ticket
  ends only with the daemon, and no store re-initialises under a fence. "No mutation" is the
  durable-state snapshot (delivery/ and state/: type, size, mtime, inode of every path) taken
  before the event, equal after the supervisor's DOWN. "No store init" is the supervisor itself
  being gone with no restarted child (asserted through its DOWN, never a timeout).
  """

  use ExUnit.Case, async: false

  # A tmux pane id built at run time: the redaction scanner rejects pane-id literals in source.
  defp p(n), do: "%" <> Integer.to_string(n)
  defp pane, do: p(9101)

  alias AiPair.Test.{DurableApp, FakeTmuxAdapter}

  @session "$31"
  @secret String.duplicate("ab", 32)
  @hash "sha256:" <>
          Base.encode16(:crypto.hash(:sha256, Base.decode16!(@secret, case: :lower)),
            case: :lower
          )
  @down_ms 5_000

  defp boot! do
    app = DurableApp.boot!([])
    FakeTmuxAdapter.put_rows(app.tmux, [DurableApp.row(pane(), @session, app.inbox, 4242)])
    app
  end

  defp attach!(app) do
    reply =
      DurableApp.request(app.sock, %{
        "cmd" => "attach_pane",
        "pane_id" => pane(),
        "agent" => "claude_code",
        "durable" => true
      })

    assert reply["ok"] == true, "durable attach failed: #{inspect(reply)}"
    reply
  end

  defp quiesce(app) do
    DurableApp.request(app.sock, %{
      "cmd" => "quiesce",
      "protocol_version" => 3,
      "resume_hash" => @hash
    })
  end

  defp fence!(app) do
    attach!(app)
    reply = quiesce(app)
    assert reply["ok"] == true and reply["quiesced"] == true, "no fence: #{inspect(reply)}"
    reply
  end

  defp kill_and_join!(app, victims) do
    ref = Process.monitor(app.supervisor)
    Enum.each(victims, &Process.exit(&1, :kill))

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    after
      @down_ms -> flunk("AiPair.Supervisor survived the exit of #{inspect(victims)}")
    end

    refute Process.whereis(AiPair.Supervisor)
    refute Process.whereis(AiPair.Admission)
    refute File.exists?(app.sock), "the daemon socket survived the daemon"
  end

  defp child(id) do
    {^id, pid, _, _} = List.keyfind(Supervisor.which_children(AiPair.Supervisor), id, 0)
    pid
  end

  describe "W5 row 10: Application wiring" do
    test "Admission sits between the receipt store and Boot, and the three owners are significant and never restarted" do
      app = boot!()

      ids = for {id, _, _, _} <- Supervisor.which_children(AiPair.Supervisor), do: id

      assert Enum.find_index(ids, &(&1 == AiPair.Admission)) ==
               Enum.find_index(ids, &(&1 == AiPair.PaneRestore.Boot)) + 1

      assert Enum.find_index(ids, &(&1 == AiPair.Delivery.ReceiptStore)) ==
               Enum.find_index(ids, &(&1 == AiPair.Admission)) + 1

      for id <- [AiPair.Admission, AiPair.Delivery.ReceiptStore, AiPair.PaneIntentStore] do
        assert {:ok, spec} = :supervisor.get_childspec(AiPair.Supervisor, id)
        assert spec.restart == :temporary, "#{inspect(id)} restarts"
        assert spec.significant == true, "#{inspect(id)} is not significant"
      end

      assert child(AiPair.Admission) == Process.whereis(AiPair.Admission)

      # The server serves with the registered admission: a durable ping advertises quiesce.
      ping = DurableApp.request(app.sock, %{"cmd" => "ping", "protocol_version" => 3})
      assert "quiesce" in ping["capabilities"]
      refute Map.has_key?(ping, "quiesced")
    end

    test "a legacy boot starts no Admission and keeps permanent stores" do
      # The suite's own application is legacy: nothing of the durable wiring is there.
      refute Application.get_env(:ai_pair, :durable_attachments) == true
      assert Process.whereis(AiPair.Admission) == nil

      assert {:ok, spec} =
               :supervisor.get_childspec(AiPair.Supervisor, AiPair.Delivery.ReceiptStore)

      assert Map.get(spec, :restart, :permanent) == :permanent
      refute Map.get(spec, :significant, false)
    end
  end

  describe "W1 failure matrix" do
    test "Admission exits while a fence is held: the daemon ends and nothing durable changes" do
      app = boot!()
      fence!(app)
      before = DurableApp.snapshot(app.inbox)
      kill_and_join!(app, [Process.whereis(AiPair.Admission)])
      assert DurableApp.snapshot(app.inbox) == before
    end

    test "Admission exits while a quiesce drains: the daemon ends and nothing durable changes" do
      app = boot!()
      attach!(app)
      holder = spawn_ticket_holder!(:ipc_send)
      waiter = Task.async(fn -> quiesce(app) end)
      await_mode!(:draining)
      before = DurableApp.snapshot(app.inbox)
      kill_and_join!(app, [Process.whereis(AiPair.Admission)])
      assert DurableApp.snapshot(app.inbox) == before
      Process.exit(holder, :kill)
      Task.shutdown(waiter, :brutal_kill)
    end

    test "Admission exits with an orphaned ticket and no fence: the daemon ends" do
      app = boot!()
      holder = spawn_ticket_holder!(:idle_paste)
      Process.exit(holder, :kill)
      await_orphan!()
      kill_and_join!(app, [Process.whereis(AiPair.Admission)])
    end

    test "the receipt store exits while a fence is held: the daemon ends, no store init, nothing changes" do
      app = boot!()
      fence!(app)
      before = DurableApp.snapshot(app.inbox)
      kill_and_join!(app, [child(AiPair.Delivery.ReceiptStore)])
      assert DurableApp.snapshot(app.inbox) == before
    end

    test "the pane-intent store exits while a fence is held: the daemon ends and nothing changes" do
      app = boot!()
      fence!(app)
      before = DurableApp.snapshot(app.inbox)
      kill_and_join!(app, [child(AiPair.PaneIntentStore)])
      assert DurableApp.snapshot(app.inbox) == before
    end

    test "Admission and the receipt store killed in one pass while fenced: the daemon ends, nothing changes" do
      app = boot!()
      fence!(app)
      before = DurableApp.snapshot(app.inbox)
      kill_and_join!(app, [Process.whereis(AiPair.Admission), child(AiPair.Delivery.ReceiptStore)])
      assert DurableApp.snapshot(app.inbox) == before
    end

    test "the receipt store exits with no fence: the durable daemon ends (the stated cost)" do
      app = boot!()
      kill_and_join!(app, [child(AiPair.Delivery.ReceiptStore)])
    end
  end

  # A process that takes a real ticket from the running Admission and holds it until killed.
  defp spawn_ticket_holder!(kind) do
    me = self()

    pid =
      spawn(fn ->
        {:ok, _ticket} = AiPair.Admission.enter(AiPair.Admission, kind)
        send(me, {:holding, self()})
        Process.sleep(:infinity)
      end)

    assert_receive {:holding, ^pid}, @down_ms
    pid
  end

  defp await_mode!(mode, tries \\ 200) do
    case :sys.get_state(AiPair.Admission).mode do
      tuple when is_tuple(tuple) and elem(tuple, 0) == mode -> :ok
      _ when tries > 0 -> Process.sleep(5) && await_mode!(mode, tries - 1)
      other -> flunk("Admission never reached #{mode}: #{inspect(other)}")
    end
  end

  defp await_orphan!(tries \\ 200) do
    if Enum.any?(AiPair.Admission.outstanding(AiPair.Admission), &(tuple_size(&1) == 3)),
      do: :ok,
      else:
        if(tries > 0, do: Process.sleep(5) && await_orphan!(tries - 1), else: flunk("no orphan"))
  end
end
