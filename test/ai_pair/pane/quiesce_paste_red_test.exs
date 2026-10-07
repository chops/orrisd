defmodule AiPair.Pane.QuiescePasteRedTest do
  @moduledoc """
  NS-32.M.002 RB-3a RED, row A7 (producer RED scope r3): a send queued behind a dialog, whose
  idle paste is attempted while a quiesce fence is held, is NOT pasted and stays queued with its
  attempt and receipt unchanged. The state machine asks AiPair.Admission for a ticket before
  begin_paste; {:error, :quiescing} means "not now", never a delivery failure.

  Harness: the real StateMachine and the shipped classifier over the shipped fixtures, a real
  ReceiptStore, and a private AiPair.Tmux whose tmux_bin is a Bash stub that only logs its argv
  (the pattern of approval_dialog_delivery_test.exs). API pinned here (GREEN; apply/3 at RED):
  StateMachine option :admission (an AiPair.Admission server).
  """

  use ExUnit.Case, async: true

  alias AiPair.Delivery.{Payload, ReceiptStore}
  alias AiPair.Pane.Classifier.Loader
  alias AiPair.Pane.StateMachine

  @fixture_root Path.expand("../../fixtures/fingerprints", __DIR__)
  @agent "claude_code"
  @dialog "claude_code/dialog_trust_gate_first_run.txt"
  @idle "claude_code/idle_001.txt"
  @text "rb3a a7 queued message"
  @poll_ms 10
  @debounce_ms 50
  @settle_polls 15
  @deadline_ms 3_000

  test "A7 an idle paste refused by a held fence leaves the send queued and its receipt unchanged" do
    h = harness()
    await(h, fn -> StateMachine.state(h.pane) == :dialog end, "dialog")

    id = "snd_" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    assert StateMachine.send_text(h.pane, @text, 1_000, id) == {:queued, :dialog}
    before = receipt_view(h, id)
    assert before.status == "queued" and before.delivery_attempt == 1

    hash = "sha256:" <> Base.encode16(:crypto.hash(:sha256, "a7"), case: :lower)
    assert {:ok, %{fence_id: _}} = apply(AiPair.Admission, :quiesce, [h.admission, hash])

    Agent.update(h.screen, fn _ -> fixture(@idle) end)
    await(h, fn -> StateMachine.state(h.pane) == :idle end, "idle")
    settle(h)

    assert recorded(h) == []
    assert StateMachine.pending_count(h.pane) == 1
    # the receipt is the same receipt: status, attempt and identities unchanged
    assert receipt_view(h, id) == before
  end

  defp harness do
    n = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "rb3a_a7_#{n}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    log = Path.join(dir, "tmux.log")
    stub = Path.join(dir, "tmux-stub")

    File.write!(stub, """
    #!/usr/bin/env bash
    {
      for arg in "$@"; do printf '%s\\037' "$arg"; done
      printf '\\n'
    } >> '#{log}'
    exit 0
    """)

    File.chmod!(stub, 0o700)
    tmux = :"rb3a_a7_tmux_#{n}"
    start_supervised!({AiPair.Tmux, name: tmux, tmux_bin: stub}, id: {:tmux, n})
    screen = start_supervised!({Agent, fn -> fixture(@dialog) end}, id: {:screen, n})

    # The admission server and its store first: at RED the row fails here, on the absent
    # AiPair.Admission, before any classifier or tmux work (local and hosted alike).
    inbox = Path.join(dir, "inbox")
    File.mkdir_p!(inbox)
    store = start_supervised!({ReceiptStore, inbox: inbox}, id: {:store, n})

    {:ok, admission} =
      apply(AiPair.Admission, :start_link, [
        [bound_ms: 60_000, receipt_store: store, observe: fn -> {:ok, %{}} end]
      ])

    {:ok, classifier, classifier_name} = Loader.load_for_agent(@agent)

    pane_id = "%rb3a_a7_#{n}"
    handler = {__MODULE__, n}
    test_pid = self()

    :ok =
      :telemetry.attach(handler, [:ai_pair, :pane, :poll], &__MODULE__.forward_poll/4, %{
        pid: test_pid,
        pane_id: pane_id
      })

    on_exit(fn -> :telemetry.detach(handler) end)

    opts = [
      pane_id: pane_id,
      agent: @agent,
      classifier: classifier,
      classifier_name: classifier_name,
      receipt_store: store,
      admission: admission,
      capture_fn: fn _pane -> {:ok, Agent.get(screen, & &1)} end,
      paste_fn: fn pane, text ->
        buffer = "ai_pair_#{System.unique_integer([:positive])}"

        with :ok <- AiPair.Tmux.set_buffer(buffer, text, tmux),
             :ok <- AiPair.Tmux.paste_buffer(pane, buffer, [delete: true], tmux) do
          AiPair.Tmux.send_keys(pane, ["Enter"], tmux)
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

    %{pane: pane, pane_id: pane_id, screen: screen, store: store, admission: admission, log: log}
  end

  @doc false
  def forward_poll(_event, _measurements, %{pane_id: pane_id, to_state: to}, %{
        pid: pid,
        pane_id: pane_id
      }),
      do: send(pid, {:rb3a_poll, pane_id, to})

  def forward_poll(_event, _measurements, _metadata, _config), do: :ok

  defp fixture(rel), do: File.read!(Path.join(@fixture_root, rel))

  defp receipt_view(h, id) do
    hash = Payload.hash(Payload.new(@text))
    {:ok, view} = ReceiptStore.reconcile(h.store, id, h.pane_id, hash, wait_ms: 0)
    # the whole view: message_id, pane_id, payload_hash, status, delivery_attempt, registration_id,
    # generation (the operation token is the state machine's own and is not observable here)
    view
  end

  defp await(h, check, what), do: do_await(h, check, what, now() + @deadline_ms)

  defp do_await(h, check, what, deadline) do
    if check.() do
      :ok
    else
      pane_id = h.pane_id

      receive do
        {:rb3a_poll, ^pane_id, _} -> do_await(h, check, what, deadline)
      after
        max(deadline - now(), 0) -> flunk("timed out waiting for #{what}")
      end
    end
  end

  # at least @settle_polls further polls of this pane, past several debounce windows
  defp settle(h) do
    pane_id = h.pane_id
    started = now()

    Enum.each(1..@settle_polls, fn _ ->
      receive do
        {:rb3a_poll, ^pane_id, _} -> :ok
      after
        @deadline_ms -> flunk("settle window not reached")
      end
    end)

    remaining = 4 * @debounce_ms - (now() - started)
    if remaining > 0, do: Process.sleep(remaining)
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp recorded(h) do
    case File.read(h.log) do
      {:ok, bytes} -> String.split(bytes, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end
end
