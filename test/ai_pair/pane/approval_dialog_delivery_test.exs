defmodule AiPair.Pane.ApprovalDialogDeliveryTest do
  @moduledoc """
  NS-30.E.001, fragment "silent classifier approval of permission prompts fails".

  A message sent to a pane that shows a permission or trust dialog must not be pasted,
  because the paste's trailing Enter would answer the dialog. This file drives the REAL
  classifier with the real `AiPair.Pane.StateMachine` over every shipped dialog fixture,
  on both send paths, and shows that nothing is pasted and the message stays queued.

  The classifier is the shipped one. Fingerprints are loaded through
  `AiPair.Pane.Classifier.Loader.load_for_agent/1`, which is the path the IPC server
  uses when it attaches a pane (`ipc/server.ex:690`). No `:fingerprint_dir` override is
  set, so the loader reads `priv/fingerprints`. The fixture directory name is the agent
  string, for example `codex_cli/dialog_*.txt` is classified with
  `load_for_agent("codex_cli")`.

  The two send paths, one witness per fixture per path:

    * plain: no receipt store, so `send_text/4` falls through to `:send_untracked`
      (`state_machine.ex:471-507`);
    * receipted: a real `AiPair.Delivery.ReceiptStore` on a unique inbox, so
      `send_text/4` is admitted and queued through `send_admitted/7`
      (`state_machine.ex:533-555`), and the queue is drained by `drain_queue/2`.

  The recorder is at the tmux boundary. The pane's `paste_fn` is the same composition as
  the production default (`state_machine.ex:851-858`) and the durable callbacks
  (`application.ex:159-167`): `set_buffer`, `paste_buffer` and `send_keys ["Enter"]`.
  Here they go through a private `AiPair.Tmux` server whose `tmux_bin` is a Bash stub
  that only appends its argv to a log and exits 0. So a paste shows up as a
  `paste-buffer` line and an Enter keypress shows up as a `send-keys ... Enter` line,
  and each is checked on its own. The stub never runs tmux and no tmux server is
  touched. `capture_fn` returns the fixture bytes.

  Each witness does the following:

    1. waits, bounded by poll telemetry, until the pane classifies the fixture as
       `:dialog`;
    2. sends, and requires the exact reply `{:queued, :dialog}`;
    3. waits past the debounce window. The window is the CONFIGURED TEST debounce,
       `idle_debounce_ms: 50` (`@debounce_ms`), not the production default of 500 ms
       (`state_machine.ex:102`). The wait is bounded: at least `@settle_polls` (15)
       further polls at the 10 ms test poll interval, and at least
       `@settle_debounces` (4) times the 50 ms test debounce, with a 3 s hard
       deadline. Every poll in the window must report `:dialog`;
    4. asserts zero `paste-buffer` and, separately, zero `send-keys Enter` in the log,
       and then that the log is empty. That rules out any partial tmux sequence, such
       as a `set-buffer` with no paste;
    5. asserts, separately, that the message is still queued: `pending_count == 1` in
       the pane's status, and for the receipted path the receipt reconciles `queued`.

  The controls use the same recorder, harness and send paths. A pane queues a message
  while it shows a dialog fixture, then its capture flips to an idle fixture of the same
  agent. The queued message must then be pasted EXACTLY once: one `set-buffer` carrying
  the text, one `paste-buffer`, one `send-keys Enter`, an empty queue, and for the
  receipted path a `delivered` receipt. This shows that the recorder can see a paste
  and that the witnesses' zeros are not vacuous.

  The fixture floor names the five shipped dialog fixtures (Codex 4, Claude 1). It
  requires each of them to exist and the glob to find at least that many, so a deleted
  fixture fails here instead of quietly dropping a witness. The per-fixture tests are
  generated from the same glob, `test/fixtures/fingerprints/*/dialog_*.txt`. It looks
  exactly one directory level deep (the agent directory), so a `dialog_*` file nested
  further down, for example under `codex_cli/streaming/`, is not found.

  Pane ids are namespaced (`%ns30e001_<n>`). The poll telemetry forwarder filters on
  pane id, so an async test elsewhere that uses a literal numeric id such as `%1`
  cannot inject its poll states into these waits.

  LIMIT. This is timing-bounded negative evidence for THESE fixtures only. It shows
  that, for the five captured screens, the shipped fingerprints classify `:dialog` and
  the state machine holds the message for the bounded window observed. It is NOT
  evidence for arbitrary future prompts. A permission prompt whose screen the
  fingerprints do not recognise is outside what this file can show. No Claude
  tool-permission prompt is synthesized here, and no fixture or fingerprint is added or
  changed.
  """

  use ExUnit.Case, async: true

  alias AiPair.Delivery.{Payload, ReceiptStore}
  alias AiPair.Pane.Classifier.Loader
  alias AiPair.Pane.StateMachine

  @fixture_root Path.expand("../../fixtures/fingerprints", __DIR__)

  @dialog_fixtures @fixture_root
                   |> Path.join("*/dialog_*.txt")
                   |> Path.wildcard()
                   |> Enum.sort()

  for path <- @dialog_fixtures, do: @external_resource(path)

  # The shipped dialog fixtures as of this file. A floor, not an exact list: a new
  # fixture gets its own generated witnesses and does not fail the floor.
  @expected_dialog_fixtures ~w(
    claude_code/dialog_trust_gate_first_run.txt
    codex_cli/dialog_trust_gate_0131_first_run.txt
    codex_cli/dialog_trust_gate_bypass.txt
    codex_cli/dialog_trust_gate_tool_approval.txt
    codex_cli/dialog_trust_gate_yolo.txt
  )

  @expected_floor %{"claude_code" => 1, "codex_cli" => 4}

  # Idle screens used only by the positive controls.
  @idle_fixtures %{
    "claude_code" => "claude_code/idle_001.txt",
    "codex_cli" => "codex_cli/idle_001.txt"
  }

  @poll_ms 10
  @debounce_ms 50
  @settle_polls 15
  @settle_debounces 4
  @deadline_ms 3_000
  @call_timeout_ms 1_000

  @text "ns30-e001 queued message"

  # ------------------------------------------------------------------ floor

  describe "fixture floor" do
    test "every shipped dialog fixture is present and the glob finds at least five" do
      found = Enum.map(@dialog_fixtures, &Path.relative_to(&1, @fixture_root))

      assert @expected_dialog_fixtures -- found == []
      assert length(found) >= 5

      by_agent = Enum.frequencies_by(found, &(&1 |> Path.dirname()))

      for {agent, floor} <- @expected_floor do
        assert Map.get(by_agent, agent, 0) >= floor
      end

      # Every fixture directory must be an agent the shipped loader resolves, or its
      # witness would not be running the real classifier.
      assert Map.keys(by_agent) -- Loader.known_agents() == []
    end

    test "the loader reads the shipped fingerprints, not an override" do
      assert Application.get_env(:ai_pair, :fingerprint_dir) == nil

      for agent <- Map.keys(@expected_floor) do
        assert {:ok, classifier, name} = Loader.load_for_agent(agent)
        assert is_function(classifier, 1)
        assert name == "fingerprint:" <> agent
      end
    end
  end

  # ---------------------------------------------------------------- witnesses

  describe "dialog fixture, plain send" do
    for path <- @dialog_fixtures do
      rel = Path.relative_to(path, @fixture_root)
      @rel rel

      test "#{rel}: no paste and the message stays queued", ctx do
        witness(ctx, @rel, :plain)
      end
    end
  end

  describe "dialog fixture, receipted send" do
    for path <- @dialog_fixtures do
      rel = Path.relative_to(path, @fixture_root)
      @rel rel

      test "#{rel}: no paste and the message stays queued", ctx do
        witness(ctx, @rel, :receipted)
      end
    end
  end

  # ----------------------------------------------------------------- controls

  describe "idle positive control on the same recorder" do
    for agent <- ["claude_code", "codex_cli"], mode <- [:plain, :receipted] do
      @agent agent
      @mode mode

      test "#{agent} #{mode}: a message queued behind a dialog pastes exactly once on idle",
           ctx do
        control(ctx, @agent, @mode)
      end
    end
  end

  # ------------------------------------------------------------------ bodies

  defp witness(ctx, rel, mode) do
    agent = Path.dirname(rel)
    h = harness(ctx, agent, mode, fixture(rel))

    await_state(h, :dialog)
    id = message_id(mode)

    assert StateMachine.send_text(h.pane, @text, @call_timeout_ms, id) == {:queued, :dialog}

    polls = settle(h)
    assert polls != []
    assert Enum.uniq(polls) == [:dialog]

    ops = recorded(h)
    assert paste_buffers(ops) == []
    assert enters(ops) == []
    assert recorded(h) == []

    status = StateMachine.status(h.pane)
    assert status.pending_count == 1
    assert status.state == :dialog

    if mode == :receipted, do: assert(receipt_status(h, id) == "queued")
  end

  defp control(ctx, agent, mode) do
    h = harness(ctx, agent, mode, fixture(dialog_of(agent)))

    await_state(h, :dialog)
    id = message_id(mode)

    assert StateMachine.send_text(h.pane, @text, @call_timeout_ms, id) == {:queued, :dialog}
    assert recorded(h) == []

    Agent.update(h.screen, fn _ -> fixture(Map.fetch!(@idle_fixtures, agent)) end)

    await(h, fn -> StateMachine.pending_count(h.pane) == 0 end, "queue to drain")
    # Past the debounce again: a second paste would have to show up in this window.
    _polls = settle(h)

    ops = recorded(h)
    assert length(paste_buffers(ops)) == 1
    assert length(enters(ops)) == 1
    assert [["set-buffer", "-b", _buffer, "--", @text]] = set_buffers(ops)
    assert [["paste-buffer", "-p", "-r", "-d", "-b", _, "-t", pane_id]] = paste_buffers(ops)
    assert pane_id == h.pane_id

    status = StateMachine.status(h.pane)
    assert status.pending_count == 0
    assert status.state == :idle

    if mode == :receipted, do: assert(receipt_status(h, id) == "delivered")
  end

  defp dialog_of(agent) do
    Enum.find(@expected_dialog_fixtures, &(Path.dirname(&1) == agent))
  end

  # ------------------------------------------------------------------ harness

  defp harness(_ctx, agent, mode, initial_screen) do
    n = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "ns30_e001_#{n}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    log = Path.join(dir, "tmux.log")
    stub = Path.join(dir, "tmux-stub")

    # Records argv, one invocation per line, fields separated by US (0x1f). Runs no tmux.
    File.write!(stub, """
    #!/usr/bin/env bash
    {
      for arg in "$@"; do printf '%s\\037' "$arg"; done
      printf '\\n'
    } >> #{escape_single(log)}
    exit 0
    """)

    File.chmod!(stub, 0o700)

    tmux = :"ns30_e001_tmux_#{n}"
    start_supervised!({AiPair.Tmux, name: tmux, tmux_bin: stub}, id: {:tmux, n})

    screen = start_supervised!({Agent, fn -> initial_screen end}, id: {:screen, n})

    assert Application.get_env(:ai_pair, :fingerprint_dir) == nil
    assert {:ok, classifier, classifier_name} = Loader.load_for_agent(agent)

    store =
      if mode == :receipted do
        inbox = Path.join(dir, "inbox")
        File.mkdir_p!(inbox)
        start_supervised!({ReceiptStore, inbox: inbox}, id: {:store, n})
      end

    pane_id = "%ns30e001_#{n}"

    handler = {__MODULE__, n}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler,
        [:ai_pair, :pane, :poll],
        &__MODULE__.forward_poll/4,
        %{pid: test_pid, pane_id: pane_id}
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    opts = [
      pane_id: pane_id,
      agent: agent,
      classifier: classifier,
      classifier_name: classifier_name,
      receipt_store: store,
      capture_fn: fn _pane -> {:ok, Agent.get(screen, & &1)} end,
      paste_fn: fn pane, text ->
        buffer = "ai_pair_#{System.unique_integer([:positive])}"

        with :ok <- AiPair.Tmux.set_buffer(buffer, text, tmux),
             :ok <- AiPair.Tmux.paste_buffer(pane, buffer, [delete: true], tmux),
             :ok <- AiPair.Tmux.send_keys(pane, ["Enter"], tmux) do
          :ok
        end
      end,
      poll_interval_ms: @poll_ms,
      idle_debounce_ms: @debounce_ms
    ]

    pane =
      start_supervised!(
        %{id: {:pane, n}, start: {StateMachine, :start_link, [opts]}, restart: :temporary},
        id: {:pane, n}
      )

    %{pane: pane, pane_id: pane_id, screen: screen, store: store, log: log}
  end

  @doc false
  def forward_poll(_event, _measurements, %{pane_id: pane_id, to_state: to}, %{
        pid: pid,
        pane_id: pane_id
      }) do
    send(pid, {:ns30_poll, pane_id, to})
  end

  def forward_poll(_event, _measurements, _metadata, _config), do: :ok

  defp escape_single(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"

  defp fixture(rel), do: File.read!(Path.join(@fixture_root, rel))

  defp message_id(:plain), do: nil

  defp message_id(:receipted),
    do: "snd_" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

  defp receipt_status(h, id) do
    hash = Payload.hash(Payload.new(@text))
    assert {:ok, view} = ReceiptStore.reconcile(h.store, id, h.pane_id, hash, wait_ms: 0)
    view.status
  end

  # ------------------------------------------------------------------ waits

  defp await_state(h, state) do
    await(h, fn -> StateMachine.state(h.pane) == state end, "pane to reach #{state}")
  end

  # Re-checks after each poll of this pane, never by sleeping, up to a hard deadline.
  defp await(h, check, what) do
    deadline = now() + @deadline_ms
    do_await(h, check, what, deadline)
  end

  defp do_await(h, check, what, deadline) do
    if check.() do
      :ok
    else
      pane_id = h.pane_id
      remaining = deadline - now()

      receive do
        {:ns30_poll, ^pane_id, _to} -> do_await(h, check, what, deadline)
      after
        max(remaining, 0) ->
          flunk("timed out after #{@deadline_ms}ms waiting for #{what}: #{inspect(recorded(h))}")
      end
    end
  end

  # Discards polls observed before this point, then collects the `to_state` of every
  # later poll until both bounds are met: `@settle_polls` polls AND
  # `@settle_debounces` * `@debounce_ms` elapsed. Returns the observed states.
  defp settle(h) do
    flush_polls(h.pane_id)
    started = now()
    do_settle(h.pane_id, started, started + @deadline_ms, [])
  end

  defp do_settle(pane_id, started, deadline, acc) do
    if length(acc) >= @settle_polls and now() - started >= @settle_debounces * @debounce_ms do
      Enum.reverse(acc)
    else
      receive do
        {:ns30_poll, ^pane_id, to} -> do_settle(pane_id, started, deadline, [to | acc])
      after
        max(deadline - now(), 0) ->
          flunk("settle window not reached in #{@deadline_ms}ms (#{length(acc)} polls)")
      end
    end
  end

  defp flush_polls(pane_id) do
    receive do
      {:ns30_poll, ^pane_id, _} -> flush_polls(pane_id)
    after
      0 -> :ok
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  # ------------------------------------------------------------------ recorder

  defp recorded(h) do
    case File.read(h.log) do
      {:ok, bytes} ->
        bytes
        |> String.split("\n", trim: true)
        |> Enum.map(&String.split(&1, <<31>>, trim: true))

      {:error, :enoent} ->
        []
    end
  end

  defp set_buffers(ops), do: Enum.filter(ops, &match?(["set-buffer" | _], &1))
  defp paste_buffers(ops), do: Enum.filter(ops, &match?(["paste-buffer" | _], &1))
  defp enters(ops), do: Enum.filter(ops, &(match?(["send-keys" | _], &1) and "Enter" in &1))
end
