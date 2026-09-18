defmodule AiPair.PaneRestore.DurableIPCRedTest do
  @moduledoc """
  The reviewed-RED demands that the R04 S9 audit row tagged for this slice, made
  to pass against the real `AiPair.IPC.Server`.

  These are the demands that are NOT about the wire bytes — the bytes are
  measured fixture by fixture in `AiPair.IPC.DurableContractFixtureTest`. What
  each row here measures is the EFFECT: which generation reached disk, how many
  marker writes were attempted, whether a pane was started, whether a record
  survived, and in which order the two halves of a withdrawal ran.

  Provenance. The reviewed RED
  (`56b5c7b:test/ai_pair/pane_restore/boot_wiring_test.exs`) builds these rows on
  a LIVE tmux server through `start_sessions!/2`, which is why R04 S11 classified
  G1-G5, G8, A1, A1b, B13 and C2 NOT-PORTABLE and carried only A2 and C1's first
  half as PORTED-PENDING S9 (`R04-S11-RECORD.org`, section 4). This run may not
  start a tmux server of any kind, so each demand is re-measured over
  `AiPair.Test.ScriptedTmux` — an owned adapter over a Bash stub that never execs
  tmux — with `AiPair.Test.RouteGuard` holding the `AiPair.Tmux` name throughout.
  The demand is the same; the fixture is not the RED's, and the rows are named
  after the demand rather than transcribed.

  The three RED demands that are measured in the fixture suite instead of here,
  because there they ARE the frozen bytes: C2's `durable_store_timeout` naming
  the unanswered call rather than an inferred filesystem stage, C2's owner loss
  reported beside the KNOWN persistence outcome, and the fence vocabulary.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias AiPair.PaneIntentStore
  alias AiPair.PaneRestore.Coordinator
  alias AiPair.PaneSupervisor
  alias AiPair.Test.PaneIntentFaultFs, as: FaultFs
  alias AiPair.Test.ReceiptBackedIPCServer
  alias AiPair.Test.RouteGuard
  alias AiPair.Test.ScriptedTmux

  @pane "%9002"
  @agent "claude_code"
  @classifier "fingerprint:claude_code"
  @session "$3"
  @session_name "s9red"
  @pane_pid 5151
  @boot_generation "8800"
  @marker_generation "12345"
  @recv_timeout_ms 20_000

  setup do
    root = Path.join(canonical_tmp(), "ai_pair_s9red_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "sock"))
    File.chmod!(Path.join(root, "sock"), 0o700)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    previous =
      Map.new([:durable_attachments, :project_binding, :tmux_server], fn key ->
        {key, Application.fetch_env(:ai_pair, key)}
      end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:ai_pair, key, value)
        {key, :error} -> Application.delete_env(:ai_pair, key)
      end)
    end)

    guard = RouteGuard.install!()
    RouteGuard.own_pane(guard, @pane)
    _ = PaneSupervisor.stop_pane(@pane)

    {:ok, root: root, guard: guard, sock: Path.join(root, "sock/ai-pair.sock")}
  end

  # ==========================================================================
  # G1, G2, G8: the marker decides what is recorded, and is never rewritten.
  # ==========================================================================

  describe "the recorded generation" do
    test "G1 the generation on disk is the one READ BACK, not the one this boot offered", c do
      # The read-back names a different generation from the one offered, which is
      # what a lost race looks like from here: the winner's claim stands and this
      # boot adopts it. Nothing else in the system can tell the two apart, so a
      # record carrying the OFFERED value would be unfalsifiable in production.
      won = "4242424242"

      dir =
        durable!(c, [
          census([row()]),
          absent_marker(),
          {"", 0},
          marker(c.root, generation: won),
          marker(c.root, generation: won),
          census([row()]),
          marker(c.root, generation: won)
        ])

      store!(c.root)

      assert %{"ok" => true, "persisted" => true} = attach!(c)
      assert [record] = records(c.root)

      assert record["session_gen"] == won
      refute record["session_gen"] == @boot_generation

      writes = writes(dir)
      assert length(writes) == 1, "the marker is offered exactly once, only on absence"

      assert Enum.any?(hd(writes), &String.contains?(&1, @boot_generation)),
             "this boot DID offer its own generation; the read-back is what overrode it"
    end

    test "G2/G8 a present same-owner marker is used unchanged, with zero writes", c do
      dir = durable!(c, happy_script(c.root))
      store!(c.root)

      assert %{"ok" => true, "persisted" => true} = attach!(c)
      assert [record] = records(c.root)
      assert record["session_gen"] == @marker_generation
      assert record["agent"] == @agent
      assert record["classifier"] == @classifier

      assert writes(dir) == [],
             "an existing claim is adopted, including its generation; no set-option runs"
    end
  end

  # ==========================================================================
  # G4, G5: an unusable marker refuses, and leaves the option byte-for-byte alone.
  # ==========================================================================

  describe "an unusable marker" do
    test "G4 a foreign marker is reported and never repaired or stolen", c do
      dir = durable!(c, [census([row()]), marker(c.root, owner_root: "/elsewhere/root")])
      store!(c.root)

      assert %{"ok" => false, "error" => "marker_foreign"} = reply = attach!(c)
      refute Map.has_key?(reply, "persisted")
      refute Map.has_key?(reply, "persist_outcome")
      refute Map.has_key?(reply, "repair_required")

      assert writes(dir) == [], "the foreign option is left byte-for-byte alone"
      assert_nothing_happened(c)
    end

    test "G5 a marker source that FAILED is uncertain, and is not an absent marker", c do
      dir = durable!(c, [census([row()]), {"no server running\n", 1, :stderr}])
      store!(c.root)

      assert %{"ok" => false, "error" => "marker_unavailable"} = reply = attach!(c)

      assert reply["persist_outcome"] == "uncertain",
             "the daemon could not establish whether it may record at all"

      refute Map.has_key?(reply, "persisted")
      refute Map.has_key?(reply, "repair_required"), "nothing was written, so nothing is owed"
      refute reply["error"] == "marker_absent"

      assert writes(dir) == []
      assert_nothing_happened(c)
    end
  end

  # ==========================================================================
  # A2: an ambiguous census is refused, never resolved by taking the first row.
  # ==========================================================================

  describe "the strict census" do
    test "A2 two rows for one pane id refuse, and the marker is never even asked", c do
      dir = durable!(c, [census([row(), row(pane_pid: 5152)])])
      store!(c.root)

      assert %{"ok" => false, "error" => "durable_observation_ambiguous"} = reply = attach!(c)
      refute Map.has_key?(reply, "persisted")

      assert_nothing_happened(c)

      assert ScriptedTmux.calls!(dir) == 1,
             "the refusal precedes the marker: only the census was invoked"

      assert ["list-panes" | _rest] = ScriptedTmux.argv!(dir, 1)
    end

    test "a pane the census does not hold is refused rather than recorded from nothing", c do
      durable!(c, [census([row(pane_id: "%7")])])
      store!(c.root)

      assert %{"error" => "durable_pane_unobserved"} = attach!(c)
      assert_nothing_happened(c)
    end
  end

  # ==========================================================================
  # A1, A1b: a store failure AFTER the start keeps the live pane and owes repair.
  # ==========================================================================

  describe "a store failure after the pane is registered" do
    test "A1 unchanged: the pane is live, the reply claims nothing, the bytes are intact", c do
      durable!(c, happy_script(c.root))
      fs = FaultFs.new()
      own_agent(fs)
      FaultFs.inject(fs, :file_sync, 1, {:error, :eio})
      store!(c.root, fs: fs)

      reply = attach!(c)

      assert reply["ok"] == false
      assert reply["error"] == "durable_write_failed"
      assert reply["persist_outcome"] == "unchanged"
      assert reply["persist_stage"] == "file_sync"
      assert reply["repair_required"] == true
      refute Map.has_key?(reply, "persisted")
      refute Map.has_key?(reply, "state"), "a post-start failure drops the child description"
      refute Map.has_key?(reply, "agent")
      refute Map.has_key?(reply, "classifier")

      assert {:ok, _pid} = PaneSupervisor.whereis_pane(@pane),
             "an unrecorded live pane is preferred over an orphan record"

      assert records(c.root) == [], "the previously committed bytes are intact: still empty"
    end

    test "A1b uncertain: the committed bytes are unknown and the owner is poisoned", c do
      durable!(c, happy_script(c.root))
      fs = FaultFs.new()
      own_agent(fs)
      FaultFs.inject(fs, :directory_sync, &state_dir?/1, {:error, :eio})
      store!(c.root, fs: fs)

      reply = attach!(c)

      assert reply["persist_outcome"] == "uncertain"
      assert reply["persist_stage"] == "directory_sync"
      assert reply["repair_required"] == true
      refute Map.has_key?(reply, "persisted")

      assert {:ok, _pid} = PaneSupervisor.whereis_pane(@pane)

      assert {:error, %{stage: :poisoned}} = PaneIntentStore.list(store_pid(c.root)),
             "a second request after an uncertain reply is expected to fail too"
    end
  end

  # ==========================================================================
  # C1: the fence covers legacy-shaped frames; with the setting unset nothing is.
  # ==========================================================================

  describe "C1 the mode gate" do
    test "in durable mode a legacy-shaped frame is fenced too, and refused without one", c do
      durable_server!(c)
      refute Process.whereis(Coordinator), "this row measures the absence of the ledger"

      assert %{"ok" => false, "error" => "coordinator_unavailable"} =
               decode(request(c, %{"cmd" => "attach_pane", "pane_id" => @pane, "agent" => @agent}))

      assert PaneSupervisor.whereis_pane(@pane) == :error, "the body never ran"

      assert %{"ok" => false, "error" => "coordinator_unavailable"} =
               decode(request(c, %{"cmd" => "detach_pane", "pane_id" => @pane}))
    end

    test "with the setting unset nothing is fenced, and no marker or store is consulted", c do
      dir = scripted_tmux!([census([row()])])
      legacy_server!(c)
      bind!(c.root)
      refute Process.whereis(Coordinator)

      attach = decode(request(c, %{"cmd" => "attach_pane", "pane_id" => @pane, "agent" => @agent}))
      detach = decode(request(c, %{"cmd" => "detach_pane", "pane_id" => @pane}))

      assert attach["ok"] == true
      assert attach["started"] == true
      assert Enum.sort(Map.keys(attach)) == ~w(agent classifier ok pane_id started state)
      assert detach == %{"ok" => true, "pane_id" => @pane, "status" => "detached"}

      assert ScriptedTmux.calls!(dir) == 0,
             "legacy mode asks the adapter nothing: no census, no marker"
    end

    test "a legacy-shaped reply is identical in both modes, member for member", c do
      legacy = legacy_server!(c)
      first = decode(request(c, %{"cmd" => "attach_pane", "pane_id" => @pane, "agent" => @agent}))
      assert %{"ok" => true} = decode(request(c, %{"cmd" => "detach_pane", "pane_id" => @pane}))

      # One socket, one listener: the legacy daemon is stopped before the
      # durable one binds the same path.
      stop_quietly(legacy)
      durable!(c, happy_script(c.root))
      store!(c.root)
      fenced = decode(request(c, %{"cmd" => "attach_pane", "pane_id" => @pane, "agent" => @agent}))

      assert fenced == first,
             "the fence changes who runs the start, never what the caller is told"
    end

    test "a legacy-mode daemon refuses an explicit durable request rather than attaching", c do
      legacy_server!(c)
      bind!(c.root)
      store!(c.root)

      assert %{"ok" => false, "error" => "durable_unavailable"} = attach!(c)
      assert_nothing_happened(c)
    end
  end

  # ==========================================================================
  # C2: a body that did not settle leaves the pane fenced unresolved.
  # ==========================================================================

  describe "C2 an unresolved pane" do
    test "the fence stays closed until an operator intervenes", c do
      durable!(c, happy_script(c.root))
      store!(c.root)

      assert {:unresolved, :did_not_settle} =
               Coordinator.transaction(@pane, fn -> {:unresolved, :did_not_settle} end)

      assert %{"ok" => false, "error" => "unresolved_operation"} = reply = attach!(c)
      assert Enum.sort(Map.keys(reply)) == ~w(error ok pane_id)
      assert_nothing_happened(c)
    end
  end

  # ==========================================================================
  # B13: the record is withdrawn BEFORE the child is stopped.
  # ==========================================================================

  describe "B13 the withdrawal order" do
    test "a withdrawal whose durable half failed leaves the child registered", c do
      durable!(c, happy_script(c.root))
      fs = FaultFs.new()
      own_agent(fs)
      # The attach's own commit is file_sync #1; the withdrawal's is #2.
      FaultFs.inject(fs, :file_sync, 2, {:error, :eio})
      store!(c.root, fs: fs)

      assert %{"persisted" => true} = attach!(c)
      assert {:ok, pid} = PaneSupervisor.whereis_pane(@pane)

      reply = decode(request(c, %{"cmd" => "detach_pane", "pane_id" => @pane}))

      assert reply["error"] == "durable_withdrawal_failed"
      assert reply["status"] == "withdrawal_failed"
      assert reply["persist_outcome"] == "unchanged"
      assert reply["repair_required"] == true
      refute Map.has_key?(reply, "persisted")
      refute Map.has_key?(reply, "pane_registered")

      assert PaneSupervisor.whereis_pane(@pane) == {:ok, pid},
             "the child is stopped only after the store confirmed the delete"

      assert [_record] = records(c.root),
             "the recorded intent survives and WILL be reasserted at the next boot"
    end

    test "a successful withdrawal deletes the record and then stops the child", c do
      durable!(c, happy_script(c.root))
      store!(c.root)

      assert %{"persisted" => true} = attach!(c)
      assert {:ok, _pid} = PaneSupervisor.whereis_pane(@pane)

      reply = decode(request(c, %{"cmd" => "detach_pane", "pane_id" => @pane}))

      assert reply["status"] == "intent_withdrawn"
      assert reply["pane_registered"] == true
      assert reply["persisted"] == true
      assert records(c.root) == []
      assert PaneSupervisor.whereis_pane(@pane) == :error
    end

    test "a detach refused for contention touches neither the record nor the child", c do
      durable!(c, happy_script(c.root))
      store!(c.root)

      assert %{"persisted" => true} = attach!(c)
      holder = hold_fence!(@pane)

      reply = decode(request(c, %{"cmd" => "detach_pane", "pane_id" => @pane}))
      send(holder, :release)

      assert Enum.sort(Map.keys(reply)) == ~w(error ok pane_id)
      assert reply["error"] == "pane_busy"
      assert [_record] = records(c.root)
      assert {:ok, _pid} = PaneSupervisor.whereis_pane(@pane)
    end
  end

  # ==========================================================================
  # The boot generation is fixed once, at server start.
  # ==========================================================================

  describe "the boot generation" do
    test "durable mode requires a non-empty ASCII decimal string", c do
      Application.put_env(:ai_pair, :durable_attachments, true)

      assert_raise ArgumentError, fn -> start_server(c, []) end
      assert_raise ArgumentError, fn -> start_server(c, boot_generation: "not-decimal") end
      assert_raise ArgumentError, fn -> start_server(c, boot_generation: "") end
      assert_raise ArgumentError, fn -> start_server(c, boot_generation: 8800) end

      assert {:ok, pid} = start_server(c, boot_generation: @boot_generation)
      stop_quietly(pid)
    end

    test "a server started in legacy mode holds no generation a later flip can supply", c do
      # The option is not read at all in legacy mode.
      legacy_server!(c)
      bind!(c.root)
      store!(c.root)
      scripted_tmux!([census([row()])])

      # Flipping the setting on afterwards is exactly the case the contract
      # names: the mode is re-read per dispatch, the generation is not.
      Application.put_env(:ai_pair, :durable_attachments, true)
      start_supervised!({Coordinator, []})

      assert %{"ok" => false, "error" => "durable_unavailable"} = attach!(c)
      refute Map.has_key?(attach!(c), "persisted")
      assert_nothing_happened(c)
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp durable!(c, steps) do
    dir = scripted_tmux!(steps)
    durable_server!(c)
    start_supervised!({Coordinator, []})
    bind!(c.root)
    dir
  end

  defp durable_server!(c) do
    Application.put_env(:ai_pair, :durable_attachments, true)
    {:ok, pid} = start_server(c, boot_generation: @boot_generation)
    on_exit(fn -> stop_quietly(pid) end)
    pid
  end

  defp legacy_server!(c) do
    Application.put_env(:ai_pair, :durable_attachments, false)
    {:ok, pid} = start_server(c, [])
    on_exit(fn -> stop_quietly(pid) end)
    pid
  end

  defp start_server(c, extra) do
    name = :"s9_red_ipc_#{System.unique_integer([:positive])}"
    ReceiptBackedIPCServer.start_link([inbox: c.root, name: name] ++ extra)
  end

  defp stop_quietly(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _reason -> :ok
      end
    end
  end

  defp attach!(c) do
    decode(
      request(c, %{
        "cmd" => "attach_pane",
        "pane_id" => @pane,
        "agent" => @agent,
        "durable" => true
      })
    )
  end

  defp request(c, payload) do
    {:ok, client} =
      :gen_tcp.connect({:local, c.sock}, 0, [:binary, {:active, false}, {:packet, 4}], 1_000)

    :ok = :gen_tcp.send(client, Jason.encode!(payload))
    {:ok, frame} = :gen_tcp.recv(client, 0, @recv_timeout_ms)
    :gen_tcp.close(client)
    frame
  end

  defp decode(frame), do: Jason.decode!(frame)

  defp assert_nothing_happened(c) do
    assert PaneSupervisor.whereis_pane(@pane) == :error, "nothing was started"

    case store_pid(c.root) do
      :undefined -> :ok
      pid -> assert PaneIntentStore.list(pid) == {:ok, []}, "nothing was written"
    end
  end

  defp bind!(root) do
    Application.put_env(:ai_pair, :project_binding, %{
      project: "s9red",
      project_dir: root,
      project_inbox: root
    })
  end

  defp store!(root, opts \\ []) do
    {:ok, pid} = PaneIntentStore.start_link([root: root] ++ opts)
    RouteGuard.own_process(pid)
    on_exit(fn -> stop_quietly(pid) end)
    pid
  end

  defp store_pid(root), do: :global.whereis_name({PaneIntentStore, Path.expand(root)})

  defp records(root) do
    {:ok, records} = PaneIntentStore.list(store_pid(root))
    records
  end

  defp own_agent({_module, agent}), do: RouteGuard.own_process(agent)

  defp state_dir?([path]), do: String.ends_with?(path, "/state")
  defp state_dir?(_args), do: false

  defp hold_fence!(pane) do
    parent = self()

    holder =
      spawn(fn ->
        Coordinator.transaction(pane, fn ->
          send(parent, :held)

          receive do
            :release -> {:ok, :released}
          after
            30_000 -> {:ok, :expired}
          end
        end)
      end)

    assert_receive :held, 5_000
    on_exit(fn -> if Process.alive?(holder), do: send(holder, :release) end)
    holder
  end

  # --- the scripted adapter --------------------------------------------------

  defp scripted_tmux!(steps) do
    {name, dir} = ScriptedTmux.start!(steps)
    Application.put_env(:ai_pair, :tmux_server, name)
    dir
  end

  # Every marker WRITE the adapter was asked to perform, as its argv. An empty
  # list is the zero-write claim, measured rather than asserted.
  defp writes(dir) do
    Enum.filter(ScriptedTmux.argvs!(dir), fn argv -> "set-option" in argv end)
  end

  defp happy_script(root) do
    [census([row()]), marker(root), marker(root), census([row()]), marker(root)]
  end

  defp census(rows), do: {Enum.map_join(rows, "", &(&1 <> "\n")), 0}

  defp row(overrides \\ []) do
    fields = [
      pane_id: @pane,
      session_id: @session,
      session_name: @session_name,
      window_index: 0,
      pane_index: 0,
      pane_pid: @pane_pid,
      command: "bash",
      path: "/private/tmp"
    ]

    Enum.map_join(fields, "|", fn {key, default} ->
      to_string(Keyword.get(overrides, key, default))
    end)
  end

  defp marker(root, overrides \\ []) do
    value = %{
      "version" => 1,
      "owner_root" => Keyword.get(overrides, :owner_root, root),
      "session_id" => Keyword.get(overrides, :session_id, @session),
      "generation" => Keyword.get(overrides, :generation, @marker_generation)
    }

    {Jason.encode!(value) <> "\n", 0}
  end

  defp absent_marker, do: {"invalid option: @ai_pair_session_incarnation\n", 1, :stderr}

  defp canonical_tmp do
    System.tmp_dir!()
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce("/", fn segment, acc ->
      joined = Path.join(acc, segment)

      case File.read_link(joined) do
        {:ok, "/" <> _rest = absolute} -> absolute
        {:ok, relative} -> Path.expand(Path.join(Path.dirname(joined), relative))
        {:error, _reason} -> joined
      end
    end)
  end
end
