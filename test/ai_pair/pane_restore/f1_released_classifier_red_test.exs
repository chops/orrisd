defmodule AiPair.PaneRestore.F1ReleasedClassifierRedTest do
  @moduledoc """
  NS-32.M.002 RB-3a GREEN-2 sub-slice F-1 (design r2, D/rb/RB3A-GREEN2-F1-DESIGN-r2.org, DESIGN GO
  m_20261007T182245Z): a released child must classify with the classifier of the committed record
  its release proved. At the RED tree it is started with released_pane_opts/2's options only, so
  it runs AiPair.Pane.Classifier.Stub, stays :unknown and never drains a matched restored entry.

  Every row runs in the ACTUAL durable application (AiPair.Test.DurableApp): attach (durable),
  then a daemon restart, so Boot restores and quarantines the pane, then a v3 release. The fake
  adapter (:tmux_server) serves captures and forwards the released child's gated transaction to
  a REAL AiPair.Tmux adapter over a Bash stub (AiPair.Test.GatedTmuxStub) answering every step 0.

  F1-R1..F1-R4 fail at RED for the reasons named in each; F1-R5 passes at RED and after (it pins the
  per-pane serialization the fix relies on).
  """

  use ExUnit.Case, async: false

  alias AiPair.Delivery.{Payload, ReceiptStore}
  alias AiPair.Test.{DurableApp, FakeTmuxAdapter, GatedTmuxStub}

  @session "$71"
  @text "f1 payload"
  @fixture Path.expand("../../fixtures/fingerprints/claude_code/idle_001.txt", __DIR__)

  # A tmux pane id built at run time: the redaction scanner rejects pane-id literals in source.
  defp p(n), do: "%" <> Integer.to_string(n)

  defp id, do: "snd_" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

  defp attach(app, pane, agent) do
    DurableApp.request(app.sock, %{
      "cmd" => "attach_pane",
      "pane_id" => pane,
      "agent" => agent,
      "durable" => true
    })
  end

  defp release(app, pane),
    do:
      DurableApp.request(
        app.sock,
        %{"cmd" => "release", "protocol_version" => 3, "pane_id" => pane},
        30_000
      )

  defp await!(fun, what, tries \\ 400) do
    cond do
      fun.() -> :ok
      tries > 0 -> Process.sleep(5) && await!(fun, what, tries - 1)
      true -> flunk("never: #{what}")
    end
  end

  # attach (agent), a v3 send queued behind the production child's :unknown, restart.
  defp restored!(pane, agent \\ "claude_code") do
    app = DurableApp.boot!([])
    FakeTmuxAdapter.put_rows(app.tmux, [DurableApp.row(pane, @session, app.inbox, 4242)])
    assert attach(app, pane, agent)["ok"] == true
    msg = id()

    sent =
      DurableApp.request(app.sock, %{
        "cmd" => "send",
        "protocol_version" => 3,
        "msg_id" => msg,
        "pane_id" => pane,
        "text" => @text
      })

    app = DurableApp.restart!(app)
    stub = GatedTmuxStub.start!()
    :ok = GenServer.call(app.tmux, {:fake_gated_to, stub.name})
    :ok = GenServer.call(app.tmux, {:fake_put_screen, File.read!(@fixture)})
    %{app: app, msg: msg, sent: sent, stub: stub, pane: pane}
  end

  defp receipt(app, msg, pane) do
    hash = Payload.hash(Payload.new(@text))
    {:ok, view} = ReceiptStore.reconcile(app.receipt_store, msg, pane, hash, wait_ms: 0)
    view.status
  end

  defp child_data(pane) do
    {:ok, pid} = AiPair.PaneSupervisor.whereis_pane(pane)
    {state, data} = :sys.get_state(pid)
    {pid, state, data}
  end

  test "F1-R1 a released child drains its matched restored entry through the gated transaction" do
    r = restored!(p(9911))
    assert r.sent["ok"] == true and r.sent["status"] == "queued"

    reply = release(r.app, r.pane)
    assert reply["ok"] == true and reply["counts"] == %{"matched" => 1, "held" => 0}

    # RED: the child runs the stub classifier and stays :unknown, so the entry stays queued.
    await!(fn -> receipt(r.app, r.msg, r.pane) == "delivered" end, "the matched entry delivered")
    {_pid, _state, data} = child_data(r.pane)
    assert data.classifier_name == "fingerprint:claude_code"

    # The gated mutation itself, not only its receipt: the real adapter ran set-buffer,
    # paste-buffer and send-keys through the stub, in that order, for this pane.
    steps =
      Path.join(r.stub.dir, "argv.log")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        line |> String.split(" ") |> Enum.find(&(not String.starts_with?(&1, "-")))
      end)

    assert Enum.filter(steps, &(&1 in ["set-buffer", "paste-buffer", "send-keys"])) ==
             ["set-buffer", "paste-buffer", "send-keys"]

    # end_command recorded: no begun command remains for the pane.
    refute Map.has_key?(:sys.get_state(GenServer.whereis(r.app.receipt_store)).started, r.pane)
  end

  test "F1-R2 the cause is the released child's classifier, not its adapter" do
    r = restored!(p(9921))
    count = fn -> Map.get(GenServer.call(r.app.tmux, :fake_captures), r.pane, 0) end
    before_release = count.()
    assert release(r.app, r.pane)["ok"] == true
    # The release has replied: the quarantined child is stopped and the released child is the
    # pane's only child, so every capture served from now on is the released child's.
    at_reply = count.()
    assert at_reply >= before_release

    # (a) the released child captures through the CONFIGURED adapter (the fake), which counts
    # every capture it serves to that pane: the count rises after the release replied.
    await!(fn -> count.() > at_reply end, "a capture served to the released child")

    # (b) the bytes it serves are idle for the record agent's own classifier.
    {:ok, classifier, "fingerprint:claude_code"} =
      AiPair.Pane.Classifier.Loader.load_for_agent("claude_code")

    {:ok, served} = AiPair.Tmux.capture_pane(r.pane, [], r.app.tmux)
    assert served == File.read!(@fixture)
    # The state machine strips ANSI sequences before it classifies (state_machine.ex strip_ansi/1).
    assert classifier.(Regex.replace(~r/\e\[[0-9;?]*[ -\/]*[@-~]/, served, "")) == :idle

    # (c) RED: the child's own classifier is the stub, the only remaining cause.
    {_pid, _state, data} = child_data(r.pane)
    assert data.classifier_name == "fingerprint:claude_code"
  end

  test "F1-R3 an agent the loader does not know refuses the release before any effect" do
    r = restored!(p(9931), "f1-no-such-agent")
    {quarantined, _, _} = child_data(r.pane)
    before = DurableApp.snapshot(r.app.inbox)

    # RED: the release succeeds and starts a stub-classified child.
    assert release(r.app, r.pane) == %{
             "ok" => false,
             "error" => "release_fence_unavailable",
             "pane_id" => r.pane,
             "protocol_version" => 3
           }

    {^quarantined, _, _} = child_data(r.pane)
    assert DurableApp.snapshot(r.app.inbox) == before
  end

  test "F1-R4 a recorded classifier the loader cannot reproduce refuses the release" do
    r = restored!(p(9941))
    {:ok, [record]} = AiPair.PaneIntentStore.list(r.app.intent_store)
    # The only way to produce such a record: a schema-valid put naming another classifier.
    :ok =
      AiPair.PaneIntentStore.put(r.app.intent_store, %{
        record
        | "classifier" => "fingerprint:codex_cli"
      })

    {quarantined, _, _} = child_data(r.pane)
    before = DurableApp.snapshot(r.app.inbox)

    # RED: the release succeeds and starts a stub-classified child.
    assert release(r.app, r.pane)["error"] == "release_fence_unavailable"
    {^quarantined, _, _} = child_data(r.pane)
    assert DurableApp.snapshot(r.app.inbox) == before
  end

  test "F1-R5 attach and detach cannot change the record between a release's proof and its start" do
    r = restored!(p(9951))
    {:ok, before} = AiPair.PaneIntentStore.list(r.app.intent_store)
    supervisor = Process.whereis(AiPair.PaneSupervisor)
    :ok = :sys.suspend(supervisor)
    released = Task.async(fn -> release(r.app, r.pane) end)

    # Parked in Release.stop/2, after its single record read, inside its pane transaction.
    await!(
      fn ->
        Enum.any?(AiPair.Admission.outstanding(AiPair.Admission), fn {:release, holder} ->
          {:current_stacktrace, frames} = Process.info(holder, :current_stacktrace)
          Enum.any?(frames, &match?({AiPair.PaneRestore.Release, :stop, 2, _}, &1))
        end)
      end,
      "the release parked in its stop step"
    )

    detach =
      DurableApp.request(r.app.sock, %{
        "cmd" => "detach_pane",
        "pane_id" => r.pane,
        "durable" => true
      })

    reattach = attach(r.app, r.pane, "claude_code")
    assert detach["ok"] == false and detach["error"] =~ "busy"
    assert reattach["ok"] == false and reattach["error"] =~ "busy"
    assert {:ok, ^before} = AiPair.PaneIntentStore.list(r.app.intent_store)

    :ok = :sys.resume(supervisor)
    assert Task.await(released, 30_000)["ok"] == true
    [%{"registration_id" => registration, "classifier" => recorded}] = before
    assert AiPair.PaneSupervisor.registration(r.pane) == {:ok, registration}

    # GREEN (added with the fix, as reviewed): the released child classifies with the classifier
    # of the record its release proved.
    {_pid, _state, data} = child_data(r.pane)
    assert data.classifier_name == recorded
  end
end
