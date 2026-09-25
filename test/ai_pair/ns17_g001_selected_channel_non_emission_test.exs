defmodule AiPair.NS17G001SelectedChannelNonEmissionTest do
  @moduledoc """
  NS-17.G.001 (Orrisd half only): NON-EMISSION IN SELECTED CHANNELS.

  Register failure control: "Daemon-owned CLI or retained auth-token bytes fail". This file
  is evidence for that Failure control only, for the Orrisd daemon only, and it is PARTIAL.
  It is not a "no token retention" test and it does not claim one.

  What it shows. A token-shaped canary, built at runtime and fresh per row, enters the
  daemon through prompt text (v2 and v1 IPC send) or through pane content (the capture
  function), and is not emitted into the SELECTED channels named below, in any of four
  forms: raw, `Base.encode64/1`, and `Base.encode16/2` lower and upper case.

  Selected (row, channel) pairs. A pair is checked only when the daemon provably writes a
  test-chosen marker into the SAME haystack during the row; the same helper first asserts
  that marker FOUND and only then asserts every canary form absent. Markers: M-ID is the
  row's msg_id, M-PANE the row's pane id, M-LOG a runtime term carried in the capture error
  of a companion pane started inside the row's log capture window.

      Row  Drive                                FILES  SPANS   TELEMETRY  LOGS   REPLIES
      R1   v2 send, idle pane, immediate paste  M-ID   M-ID    M-PANE     M-LOG  M-ID
      R2   v2 send, busy pane, queued, drained  M-ID   M-ID    M-PANE     M-LOG  M-ID
      R3   v1 send, immediate and queued        -      M-ID    M-PANE     M-LOG  M-PANE
      R4a  v2 oversize refusal                  -      M-ID    M-PANE     M-LOG  M-ID
      R4b  v2 conflict refusal                  M-ID   M-ID    M-PANE     M-LOG  M-ID
      R4c  v2 send to a dead pane               M-ID   M-ID    M-PANE     M-LOG  M-ID
      R5   pane content carries the canary      -      M-PANE  M-PANE     M-LOG  -

  The dropped pairs (R3 FILES, R4a FILES, R5 FILES, R5 REPLIES) have no provable marker
  and are NOT claimed. L0 is a standalone liveness control for the LOGS collector (the
  companion marker and a debug-level line are both captured); it does not replace the
  per-row M-LOG marker.

  NOT covered, stated rather than implied:
    * process memory, crash dumps and `:sys.get_state/1`. The pane state machine is KNOWN
      to keep the last raw capture in process state (F-1, `state_machine.ex:311`); this
      file does not contradict that and does not claim the daemon holds no token bytes;
    * the calibrator's persisted capture fixtures (F-2);
    * a failed paste or a failed tmux call, whose argv can carry the payload (F-3);
    * any real tmux binary: the only doubles are `paste_fn` and `capture_fn`;
    * encodings other than the four above (V5) and writes outside the two inbox roots (V6).
  Nothing here endorses F-1, F-2 or F-3; they belong to the separate product scope
  CLAUDE-ORRISD-NS17-BYTE-RETENTION-FINDINGS-SCOPE-r1.org.

  R6 is STATIC SPAWN-SITE EVIDENCE ONLY, at the head it runs on. It is never evidence of
  process lineage, parentage or lifetime, and the Acceptance clause (lineage, lifetime,
  launch facts) is untouched. It asserts, from the AST of every `lib/**/*.ex` file, the
  exact classified set of four process-launch calls, all `System.cmd` of tmux:
  `tmux.ex` (daemon tree, `AiPair.Tmux`), `cli/consult.ex` (client CLI, lists panes only),
  `mix/tasks/ai_pair.smoke.ex` (operator-run mix task) and `calibrator.ex` (operator-run
  calibrator). The last two DO launch agent CLIs under their own tmux servers; R6 names
  them and does not excuse them. A new launch site anywhere in lib fails R6 until it is
  classified and added in a reviewed change.

  `async: false`: the OTel exporter, the Logger level and the telemetry handlers are
  global.
  """

  use ExUnit.Case, async: false

  import AiPair.Test.OtelHelper,
    only: [setup_otel_capture: 1, drain_spans: 0, span_name: 1, span_attrs: 1]

  import ExUnit.CaptureLog, only: [with_log: 2]

  require Logger

  alias AiPair.Delivery.{Payload, ReceiptStore}
  alias AiPair.IPC.Server
  alias AiPair.Pane.StateMachine
  alias AiPair.PaneSupervisor
  alias AiPair.Test.MarkerClassifier

  @max_text_bytes 524_288

  @telemetry_events [
    [:ai_pair, :pane, :poll],
    [:ai_pair, :classifier, :decision],
    [:ai_pair, :ipc, :send_rejected],
    [:ai_pair, :pane, :reaped],
    [:ai_pair, :inbox, :stuck]
  ]

  # The exact classified set R6 asserts: {enclosing module, file, call}.
  @launch_sites [
    {AiPair.Tmux, "lib/ai_pair/tmux.ex", {System, :cmd}},
    {AiPair.CLI.Consult, "lib/ai_pair/cli/consult.ex", {System, :cmd}},
    {Mix.Tasks.AiPair.Smoke, "lib/mix/tasks/ai_pair.smoke.ex", {System, :cmd}},
    {AiPair.Calibrator, "lib/ai_pair/calibrator.ex", {System, :cmd}}
  ]

  setup :setup_otel_capture

  setup do
    n = System.unique_integer([:positive])
    inbox = Path.join(System.tmp_dir!(), "ns17_g001_" <> Integer.to_string(n))
    File.mkdir_p!(Path.join(inbox, "sock"))
    File.chmod!(Path.join(inbox, "sock"), 0o700)
    on_exit(fn -> File.rm_rf!(inbox) end)

    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    store = start_supervised!({ReceiptStore, inbox: inbox})

    start_supervised!({Server, inbox: inbox, name: :"ns17_g001_server_#{n}", receipt_store: store})

    # The paste double's record, the capture double's screen, and the raw reply bytes.
    initial_screen = %{screen: "IDLE_MARKER", captures: 0}
    paste = start_supervised!(agent_spec(:ns17_paste, []))
    screen = start_supervised!(agent_spec(:ns17_screen, initial_screen))
    replies = start_supervised!(agent_spec(:ns17_replies, []))

    test_pid = self()
    handler_id = {:ns17_g001_telemetry, n}

    :ok =
      :telemetry.attach_many(
        handler_id,
        @telemetry_events,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:ns17_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    pane = "%ns17_g001_row_" <> Integer.to_string(n)
    log_pane = "%ns17_g001_log_" <> Integer.to_string(n)
    on_exit(fn -> PaneSupervisor.stop_pane(pane) end)
    on_exit(fn -> PaneSupervisor.stop_pane(log_pane) end)

    {:ok,
     n: n,
     inbox: inbox,
     store: store,
     log: ReceiptStore.path(store),
     paste: paste,
     screen: screen,
     replies: replies,
     pane: pane,
     log_pane: log_pane,
     sock: Path.join(inbox, "sock/ai-pair.sock")}
  end

  describe "R1-R5: non-emission in selected channels" do
    test "R1: v2 prompt text pasted at once to an idle pane", c do
      canary = canary!()
      id = msg_id(c, "r1")
      text = "ns17 R1 prompt " <> canary

      {_, marker, log} =
        run_row(c, canary, fn ->
          _sm = start_row_pane!(c, :idle)

          assert %{"ok" => true, "status" => "sent"} = send_frame!(c, v2_send(c, id, text))

          assert %{"outcome" => "delivered", "delivery_attempt" => 1} =
                   reconcile!(c, id, text)

          assert statuses(c, id) == [{1, "pending"}, {1, "delivered"}]

          # V1: the canary entered the daemon and left it through the paste double.
          assert text in pasted(c)
          assert Enum.any?(pasted(c), &String.contains?(&1, canary))
        end)

      await_span!("ipc.send", "ipc.msg_id", id)
      assert_row_polled!(c)

      assert_selected_channels!(canary, [
        {"R1 FILES", files_haystack(c), [id]},
        {"R1 SPANS", spans_haystack(), [id]},
        {"R1 TELEMETRY", telemetry_haystack(), [c.pane]},
        {"R1 LOGS", log, [marker]},
        {"R1 REPLIES", replies_haystack(c), [id]}
      ])
    end

    test "R2: v2 prompt text queued on a busy pane and drained on idle", c do
      canary = canary!()
      id = msg_id(c, "r2")
      text = "ns17 R2 prompt " <> canary
      set_screen(c, "BUSY_MARKER")

      {_, marker, log} =
        run_row(c, canary, fn ->
          _sm = start_row_pane!(c, :busy)
          :ok = ReceiptStore.observe(c.store, id)

          assert %{"ok" => true, "status" => "queued", "queue_reason" => "busy"} =
                   send_frame!(c, v2_send(c, id, text))

          refute text in pasted(c), "a queued send must not paste while the pane is busy"

          set_screen(c, "IDLE_MARKER")
          assert_receive {:receipt_finalized, ^id, "delivered"}, 2_000

          assert %{"outcome" => "delivered", "delivery_attempt" => 1} =
                   reconcile!(c, id, text)

          assert statuses(c, id) == [{1, "pending"}, {1, "queued"}, {1, "delivered"}]

          # V1: the drained paste carried the canary.
          assert text in pasted(c)
        end)

      await_span!("ipc.send", "ipc.msg_id", id)
      assert_row_polled!(c)

      assert_selected_channels!(canary, [
        {"R2 FILES", files_haystack(c), [id]},
        {"R2 SPANS", spans_haystack(), [id]},
        {"R2 TELEMETRY", telemetry_haystack(), [c.pane]},
        {"R2 LOGS", log, [marker]},
        {"R2 REPLIES", replies_haystack(c), [id]}
      ])
    end

    test "R3: v1 prompt text, immediate and queued", c do
      canary = canary!()
      id_now = msg_id(c, "r3-immediate")
      id_queued = msg_id(c, "r3-queued")
      text_now = "ns17 R3 immediate " <> canary
      text_queued = "ns17 R3 queued " <> canary

      {_, marker, log} =
        run_row(c, canary, fn ->
          sm = start_row_pane!(c, :idle)

          assert %{"ok" => true, "status" => "sent", "pane_id" => pane} =
                   send_frame!(c, v1_send(c, id_now, text_now))

          assert pane == c.pane
          assert text_now in pasted(c)

          set_screen(c, "BUSY_MARKER")
          assert :ok = await_state(sm, :busy)

          assert %{"ok" => true, "status" => "queued", "queue_reason" => "busy"} =
                   reply = send_frame!(c, v1_send(c, id_queued, text_queued))

          assert reply["pane_id"] == c.pane
          refute text_queued in pasted(c)

          set_screen(c, "IDLE_MARKER")

          assert wait_until(fn -> text_queued in pasted(c) end),
                 "the queued v1 send must drain once the pane is idle"
        end)

      await_span!("ipc.send", "messaging.message.id", id_now)
      await_span!("ipc.send", "messaging.message.id", id_queued)
      assert_row_polled!(c)

      # FILES is DROPPED for R3: the v1 path writes no receipt.
      assert_selected_channels!(canary, [
        {"R3 SPANS", spans_haystack(), [id_now, id_queued]},
        {"R3 TELEMETRY", telemetry_haystack(), [c.pane]},
        {"R3 LOGS", log, [marker]},
        {"R3 REPLIES", replies_haystack(c), [c.pane]}
      ])
    end

    test "R4a: v2 oversize refusal", c do
      canary = canary!()
      id = msg_id(c, "r4a")
      text = canary <> String.duplicate("a", @max_text_bytes + 1 - byte_size(canary))
      assert byte_size(text) == @max_text_bytes + 1

      {_, marker, log} =
        run_row(c, canary, fn ->
          _sm = start_row_pane!(c, :idle)
          before = File.read!(c.log)

          reply = send_frame!(c, v2_send(c, id, text))

          # V7: this branch, and no other.
          assert reply["ok"] == false
          assert reply["error"] == "oversize"
          assert reply["msg_id"] == id
          assert File.read!(c.log) == before, "an oversize refusal admits no attempt"
          assert pasted(c) == []
        end)

      await_span!("ipc.send", "ipc.msg_id", id)
      assert_row_polled!(c)

      # FILES is DROPPED for R4a: the refusal comes before admission.
      assert_selected_channels!(canary, [
        {"R4a SPANS", spans_haystack(), [id]},
        {"R4a TELEMETRY", telemetry_haystack(), [c.pane]},
        {"R4a LOGS", log, [marker]},
        {"R4a REPLIES", replies_haystack(c), [id]}
      ])
    end

    test "R4b: v2 conflict refusal on a reused msg_id", c do
      canary = canary!()
      id = msg_id(c, "r4b")
      first_text = "ns17 R4b first " <> Integer.to_string(c.n)
      second_text = "ns17 R4b second " <> canary
      refute String.contains?(first_text, canary)

      {_, marker, log} =
        run_row(c, canary, fn ->
          _sm = start_row_pane!(c, :idle)

          # The row's first, canary-free admission of this msg_id is the FILES marker.
          assert %{"ok" => true, "status" => "sent"} =
                   send_frame!(c, v2_send(c, id, first_text))

          assert statuses(c, id) == [{1, "pending"}, {1, "delivered"}]
          assert first_text in pasted(c)
          before = File.read!(c.log)

          reply = send_frame!(c, v2_send(c, id, second_text))

          # V7: this branch, and no other.
          assert reply["ok"] == false
          assert reply["error"] == "conflict"
          assert reply["msg_id"] == id
          assert File.read!(c.log) == before, "a conflict refusal writes nothing"
          refute Enum.any?(pasted(c), &String.contains?(&1, canary))
        end)

      await_span!("ipc.send", "ipc.msg_id", id)
      assert_row_polled!(c)

      assert_selected_channels!(canary, [
        {"R4b FILES", files_haystack(c), [id]},
        {"R4b SPANS", spans_haystack(), [id]},
        {"R4b TELEMETRY", telemetry_haystack(), [c.pane]},
        {"R4b LOGS", log, [marker]},
        {"R4b REPLIES", replies_haystack(c), [id]}
      ])
    end

    test "R4c: v2 send to a dead pane", c do
      canary = canary!()
      id = msg_id(c, "r4c")
      text = "ns17 R4c prompt " <> canary

      {_, marker, log} =
        run_row(c, canary, fn ->
          sm = start_row_pane!(c, :idle)

          # M-PANE comes from the polls before the pane is marked dead.
          assert wait_until(fn -> row_polls(c) != [] end)
          StateMachine.mark_dead(sm)
          assert :ok = await_state(sm, :dead)

          reply = send_frame!(c, v2_send(c, id, text))

          # V7: this branch, and no other.
          assert reply["ok"] == false
          assert reply["error"] == "pane_dead"
          assert reply["msg_id"] == id
          assert statuses(c, id) == [{1, "pending"}, {1, "not_delivered"}]

          assert %{"outcome" => "absent", "delivery_attempt" => 1, "status" => "not_delivered"} =
                   reconcile!(c, id, text)

          refute Enum.any?(pasted(c), &String.contains?(&1, canary))
        end)

      await_span!("ipc.send", "ipc.msg_id", id)
      assert_row_polled!(c)

      assert_selected_channels!(canary, [
        {"R4c FILES", files_haystack(c), [id]},
        {"R4c SPANS", spans_haystack(), [id]},
        {"R4c TELEMETRY", telemetry_haystack(), [c.pane]},
        {"R4c LOGS", log, [marker]},
        {"R4c REPLIES", replies_haystack(c), [id]}
      ])
    end

    test "R5: pane content carrying the canary", c do
      canary = canary!()

      # The canary is on screen before the pane's first capture, so every capture
      # counted below, and every poll event, comes after it was set.
      set_screen(c, "IDLE_MARKER\n" <> canary)
      captures_at_set = captures(c)

      {_, marker, log} =
        run_row(c, canary, fn ->
          _sm = start_row_pane!(c, :idle)

          # V1: the capture counter passes 20 after the canary was set.
          assert wait_until(fn -> captures(c) - captures_at_set > 20 end),
                 "the pane must capture the canary more than 20 times"
        end)

      assert captures(c) - captures_at_set > 20
      assert_row_polled!(c)
      await_span!("pane.transition", "pane.id", c.pane)

      # FILES and REPLIES are DROPPED for R5: no poll path writes a file, and no
      # request is sent.
      assert_selected_channels!(canary, [
        {"R5 SPANS", spans_haystack(), [c.pane]},
        {"R5 TELEMETRY", telemetry_haystack(), [c.pane]},
        {"R5 LOGS", log, [marker]}
      ])
    end

    test "L0: the log collector sees the companion marker and debug-level lines", c do
      canary = canary!()
      debug_marker = "ns17dbgctl" <> Integer.to_string(System.unique_integer([:positive]))

      {_, marker, log} =
        run_row(c, canary, fn ->
          Logger.debug("ns17 L0 debug control " <> debug_marker)
          :ok
        end)

      assert String.contains?(log, marker), "the companion warning must be captured"
      assert String.contains?(log, debug_marker), "a debug-level line must be captured"
      refute String.contains?(debug_marker, canary)
    end
  end

  describe "R6: static spawn-site evidence only (never lineage proof)" do
    test "R6: lib contains exactly the four classified process-launch sites" do
      files = lib_files()

      for {_module, file, _call} <- @launch_sites do
        assert file in files, "#{file} must be walked"
      end

      found = collected_sites(files)

      # C6c: equality is a floor and a ceiling at once.
      assert Enum.sort(found) == Enum.sort(@launch_sites),
             "the process-launch sites in lib changed; classify and add them in a reviewed " <>
               "change. Found: #{inspect(found)}"

      # V8: no launch site reached through apply/2,3 on System, Port, :erlang or :os.
      refute Enum.any?(found, fn {_module, _file, {_mod, fun}} -> fun == :apply end)
    end

    test "R6: of the four enclosing modules only AiPair.Tmux is a daemon child" do
      ids = AiPair.Supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))

      # Anti-vacuity: the tree read is the running daemon tree.
      assert AiPair.PaneSupervisor in ids
      assert AiPair.Tmux in ids

      for module <- [AiPair.CLI.Consult, Mix.Tasks.AiPair.Smoke, AiPair.Calibrator] do
        refute module in ids, "#{inspect(module)} must not be a daemon child"
      end
    end

    test "R6: tmux.ex issues no session, window or respawn command; consult lists panes only" do
      tmux_literals = binary_literals(ast!("lib/ai_pair/tmux.ex"))

      # Non-blind: the same detector does see the adapter's own subcommands.
      assert "capture-pane" in tmux_literals

      for word <- forbidden_words() do
        refute word in tmux_literals, "tmux.ex must not carry the literal #{word}"
      end

      consult_literals = binary_literals(ast!("lib/ai_pair/cli/consult.ex"))
      subcommands = Enum.filter(consult_literals, &(&1 in tmux_subcommands()))
      assert Enum.uniq(subcommands) == ["list-panes"]
    end

    test "R6: no alias or import of System, Port, :erlang or :os anywhere in lib (V8)" do
      offenders =
        for file <- lib_files(), aliased_launch_module?(ast!(file)), do: file

      assert offenders == []
    end

    test "C6a: the collector finds each launch form in a quoted snippet" do
      snippets = [
        {~S|System.cmd("x", [])|, {System, :cmd}},
        {~S|Port.open({:spawn_executable, "x"}, [])|, {Port, :open}},
        {~S|:erlang.open_port({:spawn, "x"}, [])|, {:erlang, :open_port}},
        {~S|apply(System, :cmd, ["x", []])|, {System, :cmd}}
      ]

      for {source, call} <- snippets do
        hits = source |> Code.string_to_quoted!() |> launch_calls()
        assert [{_module, ^call}] = hits, "#{source} must give exactly one hit"
      end
    end

    test "C6b: the literal detector finds the session command where it exists" do
      [session_word | _] = forbidden_words()

      for file <- ["lib/ai_pair/calibrator.ex", "lib/mix/tasks/ai_pair.smoke.ex"] do
        assert session_word in binary_literals(ast!(file)),
               "#{file} carries the session command; a detector that misses it is blind"
      end
    end

    test "C6c: removing or adding any site breaks the exact-set equality" do
      found = Enum.sort(collected_sites(lib_files()))
      expected = Enum.sort(@launch_sites)
      assert found == expected

      for site <- expected do
        refute Enum.sort(found -- [site]) == expected, "a missing site must fail"
      end

      [{_module, extra} | _] =
        ~S|System.cmd("x", [])| |> Code.string_to_quoted!() |> launch_calls()

      refute Enum.sort([{Extra, "lib/extra.ex", extra} | found]) == expected,
             "an added site must fail"
    end
  end

  # ===== row harness =====

  # The whole row body runs inside one log capture window with the Logger level at
  # :debug, and a companion pane that logs the M-LOG marker on every poll.
  defp run_row(c, canary, body) do
    marker = log_marker!(canary)

    {result, log} =
      with_log([level: :debug], fn ->
        assert Logger.level() == :debug
        start_companion!(c, marker)

        try do
          result = body.()

          # The poll event precedes the warning in the same poll, so a second event
          # proves the first warning was issued inside this window.
          assert wait_until(fn -> length(polls_of(c.log_pane)) >= 2 end),
                 "the companion log-control pane must poll inside the capture window"

          result
        after
          PaneSupervisor.stop_pane(c.log_pane)
          PaneSupervisor.stop_pane(c.pane)
        end
      end)

    {result, marker, log}
  end

  defp start_row_pane!(c, target) do
    paste = c.paste
    screen = c.screen

    paste_fn = fn _pane_id, text ->
      try do
        Agent.update(paste, &[text | &1])
        :ok
      catch
        :exit, _ -> {:error, :ns17_paste_recorder_gone}
      end
    end

    capture_fn = fn _pane_id ->
      try do
        bytes = Agent.get_and_update(screen, &{&1.screen, %{&1 | captures: &1.captures + 1}})
        {:ok, bytes}
      catch
        :exit, _ -> {:error, :ns17_screen_gone}
      end
    end

    {:ok, sm} =
      PaneSupervisor.start_pane(c.pane,
        receipt_store: c.store,
        capture_fn: capture_fn,
        paste_fn: paste_fn,
        classifier: MarkerClassifier,
        poll_interval_ms: 5,
        idle_debounce_ms: 0
      )

    assert :ok = await_state(sm, target)
    sm
  end

  # M-LOG: a companion pane whose every capture fails with a term carrying the marker.
  # It carries no canary and never pastes.
  defp start_companion!(c, marker) do
    {:ok, _companion} =
      PaneSupervisor.start_pane(c.log_pane,
        capture_fn: fn _pane_id -> {:error, {:ns17_log_control, marker}} end,
        paste_fn: fn _pane_id, _text -> {:error, :ns17_companion_never_pastes} end,
        classifier: MarkerClassifier,
        poll_interval_ms: 5,
        idle_debounce_ms: 0
      )
  end

  defp agent_spec(id, initial), do: Supervisor.child_spec({Agent, fn -> initial end}, id: id)

  defp set_screen(c, screen), do: Agent.update(c.screen, &%{&1 | screen: screen})
  defp captures(c), do: Agent.get(c.screen, & &1.captures)
  defp pasted(c), do: c.paste |> Agent.get(& &1) |> Enum.reverse()

  # ===== canary and markers (runtime-built; no source line has the token shape) =====

  defp canary! do
    prefix = Enum.join(["s", "k-ant-"])
    canary = prefix <> "ns17" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
    tail = binary_part(canary, byte_size(prefix), byte_size(canary) - byte_size(prefix))

    assert byte_size(canary) >= 27
    assert byte_size(tail) >= 20
    assert tail =~ ~r/\A[A-Za-z0-9_-]+\z/
    canary
  end

  # V10: built from a different random source than the canary, and checked both ways.
  defp log_marker!(canary) do
    marker =
      "ns17logctl" <>
        Integer.to_string(:rand.uniform(1_000_000_000)) <>
        "u" <> Integer.to_string(System.unique_integer([:positive]))

    refute String.contains?(marker, canary)
    refute String.contains?(canary, marker)
    marker
  end

  defp canary_forms(canary) do
    [
      raw: canary,
      base64: Base.encode64(canary),
      hex_lower: Base.encode16(canary, case: :lower),
      hex_upper: Base.encode16(canary, case: :upper)
    ]
  end

  # Every marker FOUND first, across every pair; only then every canary form absent.
  defp assert_selected_channels!(canary, pairs) do
    for {label, haystack, markers} <- pairs, marker <- markers do
      assert String.contains?(haystack, marker),
             "#{label}: marker #{inspect(marker)} not found; the collector is blind here, " <>
               "so no absence claim may be read from it"
    end

    for {label, haystack, _markers} <- pairs, {form, value} <- canary_forms(canary) do
      refute String.contains?(haystack, value), "#{label}: canary emitted in #{form} form"
    end
  end

  # ===== collectors =====

  defp files_haystack(c) do
    [c.inbox, Application.fetch_env!(:ai_pair, :inbox)]
    |> Enum.uniq()
    |> Enum.flat_map(&Path.wildcard(&1 <> "/**/*", match_dot: true))
    |> Enum.filter(&match?({:ok, %File.Stat{type: :regular}}, File.lstat(&1)))
    |> Enum.map_join("\n", &File.read!/1)
  end

  defp spans_haystack, do: haystack(pull_spans())
  defp telemetry_haystack, do: haystack(pull_telemetry())

  defp replies_haystack(c), do: c.replies |> Agent.get(& &1) |> Enum.reverse() |> Enum.join("\n")

  defp haystack(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  defp pull_spans do
    all = Process.get(:ns17_spans, []) ++ drain_spans()
    Process.put(:ns17_spans, all)
    all
  end

  defp pull_telemetry do
    all = Process.get(:ns17_telemetry, []) ++ drain_telemetry([])
    Process.put(:ns17_telemetry, all)
    all
  end

  defp drain_telemetry(acc) do
    receive do
      {:ns17_telemetry, _event, _measurements, _metadata} = message ->
        drain_telemetry([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp polls_of(pane) do
    Enum.filter(pull_telemetry(), fn
      {:ns17_telemetry, [:ai_pair, :pane, :poll], _measurements, %{pane_id: ^pane}} -> true
      _other -> false
    end)
  end

  defp row_polls(c), do: polls_of(c.pane)

  defp assert_row_polled!(c) do
    assert row_polls(c) != [], "the row pane must emit poll telemetry carrying its pane id"
  end

  # V4: the named span must be present and carry the marker; zero spans fails.
  defp await_span!(name, key, value) do
    assert wait_until(fn ->
             Enum.any?(pull_spans(), fn span ->
               span_name(span) == name and Map.get(span_attrs(span), key) == value
             end)
           end),
           "no #{name} span carrying #{key} = #{inspect(value)} reached the exporter"
  end

  defp statuses(c, id) do
    c.log
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["message_id"] == id))
    |> Enum.map(&{&1["delivery_attempt"], &1["status"]})
  end

  # ===== frames =====

  defp msg_id(c, seed),
    do: "snd_" <> Base.encode16(:crypto.hash(:sha256, "#{seed}-#{c.n}"), case: :lower)

  defp v2_send(c, id, text) do
    %{
      "cmd" => "send",
      "protocol_version" => 2,
      "pane_id" => c.pane,
      "msg_id" => id,
      "text" => text
    }
  end

  # No protocol_version: the v1 path.
  defp v1_send(c, id, text) do
    %{"cmd" => "send", "pane_id" => c.pane, "msg_id" => id, "text" => text}
  end

  defp reconcile!(c, id, text) do
    send_frame!(c, %{
      "cmd" => "reconcile",
      "protocol_version" => 2,
      "pane_id" => c.pane,
      "msg_id" => id,
      "payload_hash" => Payload.hash(Payload.new(text)),
      "wait_ms" => 0
    })
  end

  # Records the raw reply bytes for the REPLIES channel, then decodes them.
  defp send_frame!(c, payload) do
    {:ok, client} =
      :gen_tcp.connect({:local, c.sock}, 0, [:binary, {:active, false}, {:packet, 4}], 1_000)

    try do
      :ok = :gen_tcp.send(client, Jason.encode!(payload))
      {:ok, frame} = :gen_tcp.recv(client, 0, 2_000)
      Agent.update(c.replies, &[frame | &1])
      Jason.decode!(frame)
    after
      :gen_tcp.close(client)
    end
  end

  # ===== waiting =====

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      cond do
        fun.() -> true
        System.monotonic_time(:millisecond) > deadline -> false
        true -> Process.sleep(5) && :retry
      end
    end)
    |> Enum.find(&(&1 != :retry))
  end

  defp await_state(sm, target, timeout \\ 2_000) do
    if wait_until(fn -> StateMachine.state(sm) == target end, timeout),
      do: :ok,
      else: {:timeout, StateMachine.state(sm)}
  end

  # ===== R6 detectors (AST, never text) =====

  defp lib_files, do: "lib/**/*.ex" |> Path.wildcard() |> Enum.sort()

  defp ast!(file), do: file |> File.read!() |> Code.string_to_quoted!()

  defp collected_sites(files) do
    for file <- files, {module, call} <- launch_calls(ast!(file)), do: {module, file, call}
  end

  # Every launch call in `ast`, with the name of its enclosing defmodule.
  defp launch_calls(ast) do
    {_ast, {_stack, hits}} = Macro.traverse(ast, {[], []}, &enter/2, &leave/2)
    Enum.reverse(hits)
  end

  defp enter({:defmodule, _, [name, _body]} = node, {stack, hits}),
    do: {node, {[module_name(name, stack) | stack], hits}}

  defp enter(node, {stack, hits} = acc) do
    case launch(node) do
      nil -> {node, acc}
      call -> {node, {stack, [{List.first(stack), call} | hits]}}
    end
  end

  defp leave({:defmodule, _, [_name, _body]} = node, {[_ | stack], hits}),
    do: {node, {stack, hits}}

  defp leave(node, acc), do: {node, acc}

  defp module_name({:__aliases__, _, parts}, stack) do
    cond do
      not Enum.all?(parts, &is_atom/1) -> :unresolved
      stack == [] -> Module.concat(parts)
      true -> Module.concat([hd(stack) | parts])
    end
  end

  defp module_name(name, _stack) when is_atom(name), do: name
  defp module_name(_name, _stack), do: :unresolved

  defp launch({{:., _, [{:__aliases__, _, [:System]}, fun]}, _, args})
       when fun in [:cmd, :shell] and is_list(args),
       do: {System, fun}

  defp launch({{:., _, [{:__aliases__, _, [:Port]}, :open]}, _, args}) when is_list(args),
    do: {Port, :open}

  defp launch({{:., _, [:erlang, :open_port]}, _, args}) when is_list(args),
    do: {:erlang, :open_port}

  defp launch({{:., _, [:os, :cmd]}, _, args}) when is_list(args), do: {:os, :cmd}

  defp launch({:open_port, _, [_name, _settings]}), do: {:erlang, :open_port}

  defp launch({:apply, _, [target, fun | rest]}) when length(rest) <= 1,
    do: applied(target, fun)

  defp launch({{:., _, [{:__aliases__, _, [:Kernel]}, :apply]}, _, [target, fun | rest]})
       when length(rest) <= 1,
       do: applied(target, fun)

  defp launch(_node), do: nil

  defp applied(target, fun) do
    module =
      case target do
        {:__aliases__, _, [:System]} -> System
        {:__aliases__, _, [:Port]} -> Port
        :erlang -> :erlang
        :os -> :os
        _other -> nil
      end

    cond do
      is_nil(module) -> nil
      is_atom(fun) -> {module, fun}
      true -> {module, :apply}
    end
  end

  defp aliased_launch_module?(ast) do
    ast
    |> Macro.prewalk(false, fn
      {directive, _, [target | _]} = node, acc when directive in [:alias, :import] ->
        {node, acc or launch_module?(target)}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  defp launch_module?({:__aliases__, _, [name]}), do: name in [:System, :Port]
  defp launch_module?(name), do: name in [:erlang, :os]

  defp binary_literals(ast) do
    ast
    |> Macro.prewalk([], fn
      node, acc when is_binary(node) -> {node, [node | acc]}
      node, acc -> {node, acc}
    end)
    |> elem(1)
  end

  # Built at runtime from one string, so no list literal in this file carries a
  # session-starting argv element.
  defp forbidden_words do
    String.split("new-session new-window split-window respawn-pane respawn-window")
  end

  defp tmux_subcommands do
    String.split(
      "capture-pane delete-buffer display-message kill-pane kill-server kill-session " <>
        "list-panes list-sessions list-windows new-session new-window paste-buffer " <>
        "pipe-pane respawn-pane respawn-window run-shell select-pane send-keys set-buffer " <>
        "set-option show-options split-window"
    )
  end
end
