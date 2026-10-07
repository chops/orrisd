defmodule AiPair.PaneRestore.S3aReleaseRedTest do
  @moduledoc """
  NS-15.G.003 S3a RED (scope r12 GO; Charles decisions 49 and 50): the version 3 `release` of a
  boot-restored quarantined pane, the gated delivery transaction and the effect journal.

  - `release` proves the pane's exact {registration_id, generation} under the pane's Coordinator
    fence, then replaces the quarantined child with a released one bound to that identity.
  - A released pane pastes only restored entries recorded with that exact pair, each through ONE
    gated Tmux transaction: begin, set-buffer, paste-buffer -d, send-keys Enter, cleanup, end.
    Unmatched entries are HELD: never pasted, kept, listed.
  - `<inbox>/delivery/effects.jsonl` records begin/end/residual lines; an uncleared begin holds
    its pane (EFFECT_UNRESOLVED); a corrupt complete line refuses the store start.
  - The guarantee is acknowledgement-only (decision 50): nothing here claims pane-side receipt.

  The rows reach release through `AiPair.IPC.DeliveryV3.dispatch/2` with a context that adds
  `pane_opts` (the released child's capture/paste/tmux options) and optional `release_ops`
  fault hooks ({stop, issue, start}). GREEN-only functions (`ReceiptStore.effect_status/1`,
  `AiPair.Tmux.gated_paste/4`) are reached through apply/3 so the file compiles at the base.
  At Orrisd 44c9577c every row but R16's legacy half fails: release is an unknown command.
  """

  use ExUnit.Case, async: false

  alias AiPair.Delivery.{Payload, ReceiptStore, SystemFs}
  alias AiPair.IPC.{Delivery, DeliveryV3}
  alias AiPair.Pane.StateMachine
  alias AiPair.PaneRestore.Coordinator
  alias AiPair.PaneSupervisor
  alias AiPair.Test.MarkerClassifier

  @reg "reg_" <> String.duplicate("5a", 16)
  @other_reg "reg_" <> String.duplicate("a5", 16)
  @gen "9301"
  @binding %{registration_id: @reg, generation: @gen}

  setup do
    n = System.unique_integer([:positive])
    inbox = Path.join(System.tmp_dir!(), "s3a-red-#{n}")
    File.mkdir_p!(inbox)
    on_exit(fn -> File.rm_rf!(inbox) end)

    start_supervised!({Coordinator, [name: Coordinator]}, restart: :temporary)
    witness = start_supervised!({Agent, fn -> [] end}, id: :witness)
    records = start_supervised!({Agent, fn -> %{} end}, id: :records)

    {:ok, inbox: inbox, pane: "%s3a_#{n}", n: n, witness: witness, records: records}
  end

  # ===== identity before anything =====

  test "R1 release refuses pane_identity_unavailable before any fence, stop or paste", c do
    for {label, prepare} <- [
          mismatch: fn c -> commit(c, @other_reg) end,
          no_record: fn _c -> :ok end,
          store_error: fn _c -> :store_error end,
          legacy: fn c ->
            commit(c, @reg)
            :legacy
          end
        ] do
      # each label has its own inbox and store: no store shares an inbox
      inbox = Path.join(c.inbox, "label_#{label}")
      File.mkdir_p!(inbox)
      c = restored!(%{c | pane: c.pane <> "_#{label}", inbox: inbox}, [{"r1", @binding}])
      before = receipts(c.inbox)
      pid = pane_pid!(c)

      ctx =
        case prepare.(c) do
          :store_error -> %{context(c) | committed: fn _ -> :error end}
          :legacy -> %{context(c) | durable: false}
          _ -> context(c)
        end

      assert %{ok: false, error: "pane_identity_unavailable"} = release(c, ctx), inspect(label)
      assert pane_pid!(c) == pid and quarantined?(pid), inspect(label)
      assert receipts(c.inbox) == before
      assert witness(c) == []
    end
  end

  test "R2 release while the pane's Coordinator lock is held refuses release_fence_unavailable and changes nothing",
       c do
    c = restored!(c, [{"r2", @binding}])
    commit(c, @reg)
    pid = pane_pid!(c)
    test = self()

    holder =
      Task.async(fn ->
        Coordinator.transaction(c.pane, fn ->
          send(test, :held)
          # Coordinator.transaction/2 requires a tagged body result
          receive do: (:go -> {:ok, :held_then_released})
        end)
      end)

    assert_receive :held, 2_000
    assert %{ok: false, error: "release_fence_unavailable"} = release(c, context(c))
    send(holder.pid, :go)
    Task.await(holder)

    assert pane_pid!(c) == pid and quarantined?(pid)
    assert witness(c) == []
  end

  # ===== the release transitions =====

  test "R3 a stop failure refuses release_stop_failed; the old child stays quarantined and the entries queued",
       c do
    c = with_tmux(c, %{})
    c = restored!(c, [{"r3", @binding}])
    commit(c, @reg)
    pid = pane_pid!(c)
    ctx = Map.put(context(c), :release_ops, %{stop: fn _pane -> {:error, :timeout} end})

    assert %{ok: false, error: "release_stop_failed"} = release(c, ctx)
    assert Process.alive?(pid) and quarantined?(pid)
    assert last_status(c.inbox, id("r3")) == "queued"
    assert witness(c) == []
  end

  # A quarantined child needs no release capability (c4 r2): an issue failure, even a
  # permanent one, re-quarantines; only a failed quarantined start is release_unstarted (R5).
  test "R4 an issue failure re-quarantines, even when every issue fails; nothing is pasted", c do
    c = with_tmux(c, %{})
    c = restored!(c, [{"r4", @binding}])
    commit(c, @reg)
    ctx = Map.put(context(c), :release_ops, %{issue: fail_first_issue()})

    assert %{ok: false, error: "release_failed_requarantined"} = release(c, ctx)
    assert quarantined?(pane_pid!(c))

    ctx2 = Map.put(context(c), :release_ops, %{issue: fn _pane, _ref -> {:error, :injected} end})
    assert %{ok: false, error: "release_failed_requarantined"} = release(c, ctx2)
    assert quarantined?(pane_pid!(c))
    assert last_status(c.inbox, id("r4")) == "queued"
    assert witness(c) == []
  end

  test "R5 a released-child start failure follows the same two branches", c do
    c = with_tmux(c, %{})
    c = restored!(c, [{"r5", @binding}])
    commit(c, @reg)
    ctx = Map.put(context(c), :release_ops, %{start: fail_released_start()})

    assert %{ok: false, error: "release_failed_requarantined"} = release(c, ctx)
    assert quarantined?(pane_pid!(c))

    ctx2 = Map.put(context(c), :release_ops, %{start: fn _pane, _opts -> {:error, :injected} end})
    assert %{ok: false, error: "release_unstarted"} = release(c, ctx2)
    assert PaneSupervisor.whereis_pane(c.pane) == :error
    assert witness(c) == []
  end

  test "R5b a failed fallback fence starts no fallback child: release_unstarted, entries queued",
       c do
    c = with_tmux(c, %{})
    c = restored!(c, [{"r5b", @binding}])
    commit(c, @reg)
    {:ok, calls} = Agent.start(fn -> 0 end)

    fence = fn pane ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> {:default, pane}
        _ -> {:error, :injected}
      end
    end

    ctx = Map.put(context(c), :release_ops, %{start: fail_released_start(), fence: fence})

    assert %{ok: false, error: "release_unstarted"} = release(c, ctx)
    assert PaneSupervisor.whereis_pane(c.pane) == :error
    assert last_status(c.inbox, id("r5b")) == "queued"
    assert witness(c) == []
  end

  test "R6 success replies the identity and counts; the child is released and a transient restart stays released",
       c do
    c = with_tmux(c, %{})
    c = restored!(c, [{"r6", @binding}])
    commit(c, @reg)

    assert %{ok: true, released: true, pane_identity: identity, counts: %{matched: 1, held: 0}} =
             release(c, context(c))

    assert {identity.registration_id, identity.generation} == {@reg, @gen}
    pid = pane_pid!(c)
    refute quarantined?(pid)

    await_restart_budget()
    Process.exit(pid, :kill)

    new =
      eventually(fn ->
        case PaneSupervisor.whereis_pane(c.pane) do
          {:ok, p} when p != pid -> p
          _ -> nil
        end
      end)

    refute quarantined?(new)
  end

  # ===== the gated delivery transaction =====

  test "R7 matched entries paste in seq order through one gated transaction each; failure variants are ambiguous",
       c do
    c = with_tmux(c, %{})
    c = restored!(c, [{"r7a", @binding}, {"r7b", @binding}])
    commit(c, @reg)
    assert %{ok: true, counts: %{matched: 2}} = release(c, context(c))

    eventually(fn -> last_status(c.inbox, id("r7b")) == "delivered" end)

    assert verbs(c) == ~w(set-buffer paste-buffer send-keys set-buffer paste-buffer send-keys)
    assert Enum.map(effects(c.inbox), & &1["kind"]) == ~w(begin end begin end)
    assert Enum.all?(effects(c.inbox), &(&1["kind"] == "begin" or &1["code"] == 0))

    for {step, expected} <- [
          {"set-buffer", ~w(set-buffer delete-buffer)},
          {"paste-buffer", ~w(set-buffer paste-buffer delete-buffer)},
          {"send-keys", ~w(set-buffer paste-buffer send-keys)}
        ] do
      # each variant has its own inbox, store, pane and stub: no store shares an inbox
      inbox = Path.join(c.inbox, "variant-" <> step)
      File.mkdir_p!(inbox)

      # a pane id admits no "-": the variant suffix uses "_"
      suffix = "_" <> String.replace(step, "-", "_")

      c2 =
        %{c | pane: c.pane <> suffix, inbox: inbox} |> Map.delete(:store) |> Map.delete(:tmux)

      c2 = with_tmux(c2, %{fail: step})
      c2 = restored!(c2, [{"r7-" <> step, @binding}])
      commit(c2, @reg)
      assert %{ok: true} = release(c2, context(c2))
      eventually(fn -> last_status(c2.inbox, id("r7-" <> step)) == "ambiguous" end)
      assert verbs(c2) == expected, step

      assert effect_status(c2.store).unresolved == [],
             "a completed nonzero transaction holds no pane"
    end
  end

  test "R7b without a tmux adapter release refuses before any change; nothing is pasted", c do
    c = restored!(c, [{"r7b", @binding}])
    commit(c, @reg)
    pid = pane_pid!(c)

    assert %{ok: false, error: "release_fence_unavailable"} = release(c, context(c))
    assert pane_pid!(c) == pid and quarantined?(pid), "the quarantined child is untouched"
    assert witness(c) == [], "no ordinary paste of a matched restored entry"
    assert last_status(c.inbox, id("r7b")) == "queued"
  end

  test "R8 unmatched entries are held: never pasted, kept with their objects, listed and not re-handed",
       c do
    c = with_tmux(c, %{})
    c = restored!(c, [{"r8-null", nil}, {"r8-other", %{@binding | registration_id: @other_reg}}])
    commit(c, @reg)

    assert %{ok: true, counts: %{matched: 0, held: 2}} = release(c, context(c))
    Process.sleep(200)

    assert verbs(c) == []
    assert last_status(c.inbox, id("r8-null")) == "queued"
    assert last_status(c.inbox, id("r8-other")) == "queued"

    assert Enum.sort(effect_status(c.store).held[c.pane]) ==
             Enum.sort([{id("r8-null"), 1}, {id("r8-other"), 1}])

    assert object_count(c.inbox) == 2

    await_restart_budget()
    Process.exit(pane_pid!(c), :kill)
    Process.sleep(200)
    assert verbs(c) == [], "a re-claim never hands a held entry"
  end

  test "R9 a daemon restart re-quarantines; paste_started is ambiguous; queued and held entries are restored",
       c do
    c = with_tmux(c, %{block: "send-keys"})
    c = restored!(c, [{"r9-m", @binding}, {"r9-u", nil}])
    commit(c, @reg)
    assert %{ok: true} = release(c, context(c))
    eventually(fn -> "send-keys" in verbs(c) end)

    c = restart_daemon!(c)
    c = readmit!(c)

    assert quarantined?(pane_pid!(c))
    assert last_status(c.inbox, id("r9-m")) == "ambiguous"
    assert last_status(c.inbox, id("r9-u")) == "queued"
  end

  test "R10 fence ordering: no tmux invocation after a fence; a fence during a command waits for its end",
       c do
    c = with_tmux(c, %{block: "paste-buffer"})
    c = restored!(c, [{"r10", @binding}])
    commit(c, @reg)
    assert %{ok: true} = release(c, context(c))
    eventually(fn -> "paste-buffer" in verbs(c) end)

    fence = fence_task(c, 30_000)

    Process.sleep(200)
    assert is_map(effect_status(c.store)), "the store answers while a fence is pending"
    refute Task.yield(fence, 0), "the fence waits for the STARTED transaction"

    unblock(c)
    assert {:ok, {:ok, {:ok, _ref}}} = Task.await(fence, 30_000)
    count = length(verbs(c))
    Process.sleep(300)
    assert length(verbs(c)) == count, "no invocation after the fence took effect"
  end

  # The second-fence fence_pending refusal is not reachable through the Coordinator (the first
  # fence's transaction holds the pane's lock); it is measured at the store, gate test G3.
  test "R11 a command outliving the fence bound: command_in_flight once, tokens live, a retried fence succeeds",
       c do
    c = with_tmux(c, %{block: "set-buffer"})
    c = restored!(c, [{"r11", @binding}])
    commit(c, @reg)
    assert %{ok: true} = release(c, context(c))
    eventually(fn -> "set-buffer" in verbs(c) end)

    assert {:ok, {:ok, {:error, :command_in_flight}}} = Task.await(fence_task(c, 60_000), 60_000)

    unblock(c)
    eventually(fn -> last_status(c.inbox, id("r11")) == "delivered" end)
    assert effect_status(c.store).unresolved == []
    assert {:ok, {:ok, {:ok, _}}} = Task.await(fence_task(c, 30_000), 30_000)
  end

  test "R12 a Tmux server killed between begin and end holds the pane: release, identity and begin refuse",
       c do
    c = with_tmux(c, %{block: "paste-buffer"})
    c = restored!(c, [{"r12", @binding}, {"r12b", @binding}])
    commit(c, @reg)
    assert %{ok: true} = release(c, context(c))
    eventually(fn -> "paste-buffer" in verbs(c) end)

    Process.exit(Process.whereis(c.tmux), :kill)
    eventually(fn -> c.pane in effect_status(c.store).unresolved end)

    assert %{ok: false, error: "effect_unresolved"} = release(c, context(c))
    assert %{ok: false, error: "pane_identity_unavailable"} = status(c)
    unblock(c)
    Process.sleep(300)
    refute Enum.count(verbs(c), &(&1 == "set-buffer")) > 1, "no second transaction begins"
  end

  test "R13 the store killed during a blocked command: the restarted store holds the pane; no additional invocation",
       c do
    c = with_tmux(c, %{block: "paste-buffer"})
    c = restored!(c, [{"r13", @binding}])
    commit(c, @reg)
    assert %{ok: true} = release(c, context(c))
    eventually(fn -> "paste-buffer" in verbs(c) end)

    stop(c.store)
    store = start_store!(c.inbox)
    c = %{c | store: store}
    assert c.pane in effect_status(store).unresolved

    count = length(verbs(c))
    unblock(c)
    Process.sleep(300)
    assert length(verbs(c)) == count
    assert c.pane in effect_status(store).unresolved
  end

  test "R14 a daemon restart with an uncleared marker: quarantined, effect_unresolved listed, attempt ambiguous",
       c do
    c = with_tmux(c, %{block: "paste-buffer"})
    c = restored!(c, [{"r14", @binding}])
    commit(c, @reg)
    assert %{ok: true} = release(c, context(c))
    eventually(fn -> "paste-buffer" in verbs(c) end)

    c = restart_daemon!(c)
    c = readmit!(c)
    assert quarantined?(pane_pid!(c))
    assert c.pane in effect_status(c.store).unresolved
    assert last_status(c.inbox, id("r14")) == "ambiguous"
    assert %{ok: false, error: "effect_unresolved"} = release(c, context(c))
  end

  test "R15 journal repair: a torn tail is truncated, a corrupt line refuses the store, compaction is canonical",
       c do
    path = Path.join([c.inbox, "delivery", "effects.jsonl"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, ~s({"schema":"ai-pair/paste-effect","v":1,"kind":"beg))
    store = start_store!(c.inbox)
    assert effect_status(store).unresolved == []
    assert File.read!(path) == ""
    stop(store)

    File.write!(path, ~s({"schema":"ai-pair/paste-effect","v":1,"kind":"nonsense"}\n))
    before = File.read!(path)

    assert {:error, {:effect_journal_corrupt, 1}} =
             GenServer.start(ReceiptStore, store_opts(c.inbox))

    assert File.read!(path) == before

    # the corrupt fixture is removed before the residual half starts its own store on this inbox
    File.rm!(path)
    c = with_tmux(c, %{fail: "paste-buffer", fail_cleanup: true})
    c = restored!(c, [{"r15", @binding}])
    commit(c, @reg)
    assert %{ok: true} = release(c, context(c))
    eventually(fn -> last_status(c.inbox, id("r15")) == "ambiguous" end)
    assert [%{buffer: "ai_pair_" <> _, msg_id: msg}] = effect_status(c.store).residual
    assert msg == id("r15")

    stop(c.store)
    first = start_store!(c.inbox)
    compacted = File.read!(path)
    assert Enum.map(effects(c.inbox), & &1["kind"]) == ["retained"]
    stop(first)
    stop(start_store!(c.inbox))
    assert File.read!(path) == compacted, "compaction is idempotent"
  end

  test "R16 ping advertises release only in durable mode; version 2 refuses release as unsupported_command",
       c do
    store = start_store!(c.inbox)
    c = Map.put(c, :store, store)

    assert "release" in DeliveryV3.dispatch(%{"cmd" => "ping", "protocol_version" => 3}, context(c)).capabilities

    refute "release" in DeliveryV3.dispatch(%{"cmd" => "ping", "protocol_version" => 3}, %{
             context(c)
             | durable: false
           }).capabilities

    reply =
      Delivery.dispatch(%{"cmd" => "release", "protocol_version" => 2, "pane_id" => "%x"}, store)

    assert %{ok: false, error: "unsupported_command", cmd: "release"} = reply
  end

  test "R17 a release of a pane with no restored entries only lifts the quarantine", c do
    c = with_tmux(c, %{})
    c = restored!(c, [])
    commit(c, @reg)

    assert %{ok: true, released: true, counts: %{matched: 0, held: 0}} = release(c, context(c))
    refute quarantined?(pane_pid!(c))
    assert witness(c) == []
  end

  # ===== harness =====

  defp release(c, ctx),
    do:
      DeliveryV3.dispatch(%{"cmd" => "release", "protocol_version" => 3, "pane_id" => c.pane}, ctx)

  defp status(c),
    do:
      DeliveryV3.dispatch(
        %{"cmd" => "status", "protocol_version" => 3, "pane_id" => c.pane},
        context(c)
      )

  defp effect_status(store), do: apply(ReceiptStore, :effect_status, [store])

  # A fence is authorized only for the pane's Coordinator transaction holder (S2): the fence
  # request is submitted inside one, as release does. Replies {:ok, submit_result}.
  defp fence_task(c, timeout) do
    Task.async(fn ->
      Coordinator.transaction(c.pane, fn ->
        {:ok, Coordinator.submit(c.pane, c.store, {:fence_restore, c.pane, make_ref()}, timeout)}
      end)
    end)
  end

  defp context(c) do
    %{
      receipt_store: c.store,
      durable: true,
      committed: fn pane ->
        case Agent.get(c.records, &Map.get(&1, pane)) do
          nil -> :none
          record -> {:ok, record}
        end
      end,
      current_pid: fn _pane -> {:ok, 4242} end,
      pane_opts: fn _pane -> {:ok, pane_opts(c)} end
    }
  end

  defp pane_opts(c) do
    witness = c.witness

    [
      capture_fn: fn _ -> {:ok, "IDLE_MARKER"} end,
      paste_fn: fn _pane, bytes -> Agent.update(witness, &(&1 ++ [bytes])) end,
      classifier: MarkerClassifier,
      poll_interval_ms: 5,
      idle_debounce_ms: 0
    ] ++ if(Map.has_key?(c, :tmux), do: [tmux_server: c.tmux], else: [])
  end

  defp commit(c, registration_id) do
    record = %{"registration_id" => registration_id, "session_gen" => @gen}
    Agent.update(c.records, &Map.put(&1, c.pane, record))
    true
  end

  # The S2 prerequisite: queue each {seed, binding} under a real store, restart it, and admit the
  # pane quarantined with its restore capability, as boot reconciliation does.
  defp restored!(c, seeds) do
    first = start_store!(c.inbox)

    for {seed, binding} <- seeds do
      hash = Payload.hash(Payload.new(bytes(seed)))

      {:ok, {:admitted, %{operation_token: token}}} =
        if binding,
          do: ReceiptStore.admit(first, id(seed), c.pane, hash, self(), binding),
          else: ReceiptStore.admit(first, id(seed), c.pane, hash, self())

      :ok = ReceiptStore.queue(first, id(seed), token, bytes(seed))
    end

    stop(first)
    readmit!(Map.put(c, :store, start_store!(c.inbox)))
  end

  defp readmit!(c) do
    store = Map.get(c, :store) || start_store!(c.inbox)

    restore =
      case Coordinator.submit(c.pane, store, {:issue_restore_capability, c.pane, make_ref()}, 5_000) do
        {:ok, {:ok, cap}} -> [receipt_store: store, restore_capability: cap]
        _ -> [receipt_store: store]
      end

    {:ok, _pid} =
      PaneSupervisor.start_pane(
        c.pane,
        [quarantine_token: "q_#{c.n}", registration_id: @reg] ++ pane_opts(c) ++ restore
      )

    on_exit(fn -> PaneSupervisor.stop_pane(c.pane) end)
    Map.put(c, :store, store)
  end

  defp restart_daemon!(c) do
    PaneSupervisor.stop_pane(c.pane)
    stop(c.store)
    if Map.has_key?(c, :tmux), do: stop(Process.whereis(c.tmux))
    Map.put(c, :store, start_store!(c.inbox))
  end

  defp store_opts(inbox),
    do: [inbox: inbox, fs: SystemFs.new(), restore_issuer: Coordinator]

  defp start_store!(inbox) do
    assert {:ok, pid} = GenServer.start(ReceiptStore, store_opts(inbox))
    on_exit(fn -> stop(pid) end)
    pid
  end

  defp stop(nil), do: :ok

  defp stop(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    end

    :ok
  end

  defp pane_pid!(c) do
    assert {:ok, pid} = PaneSupervisor.whereis_pane(c.pane)
    pid
  end

  defp quarantined?(pid), do: StateMachine.status(pid).quarantined

  # R6 and R8 kill a pane child on purpose. AiPair.PaneSupervisor is one named DynamicSupervisor
  # shared by every test file, with the default intensity (more than 3 restarts within 5 s,
  # counted in whole seconds, exits it :shutdown). Kills in other files (quarantine_test's
  # transient-restart rows) can fall in the same window (local runs r6 and r8 run 3), so a
  # deliberate kill first waits until the window holds fewer than max_restarts restarts
  # (the shared AiPair.Test.PaneSupervisorBudget, which raises rather than kill into an exhausted
  # budget).
  defp await_restart_budget, do: AiPair.Test.PaneSupervisorBudget.await!()

  defp fail_first_issue do
    {:ok, flag} = Agent.start(fn -> :first end)

    fn pane, ref ->
      case Agent.get_and_update(flag, &{&1, :later}) do
        :first -> {:error, :injected}
        :later -> {:default, pane, ref}
      end
    end
  end

  defp fail_released_start do
    fn pane, opts ->
      if Keyword.has_key?(opts, :quarantine_token),
        do: {:default, pane, opts},
        else: {:error, :injected}
    end
  end

  # A real AiPair.Tmux server whose tmux_bin is a bash stub: each invocation appends its
  # subcommand to a log; `fail` makes one subcommand exit 1 (`fail_cleanup` also fails
  # delete-buffer); `block` makes one subcommand wait on a FIFO until `unblock/1`.
  defp with_tmux(c, mode) do
    dir = Path.join(c.inbox, "tmux-stub-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    log = Path.join(dir, "log")
    gate = Path.join(dir, "gate")
    File.write!(log, "")
    if mode[:block], do: {_, 0} = System.cmd("mkfifo", [gate])

    lines = [
      "#!/usr/bin/env bash",
      # AiPair.Tmux prepends ["-L", socket]: skip each option, and the argument of -L/-S, to reach the command
      ~S{sub=""; skip=0; for a in "$@"; do if [ "$skip" = 1 ]; then skip=0; continue; fi; case "$a" in -L|-S) skip=1;; -*) ;; *) sub="$a"; break;; esac; done},
      "printf '%s\\n' \"$sub\" >> '#{log}'",
      if(mode[:block], do: "[ \"$sub\" = '#{mode[:block]}' ] && read -r _ < '#{gate}'", else: ":"),
      if(mode[:fail], do: "[ \"$sub\" = '#{mode[:fail]}' ] && exit 1", else: ":"),
      if(mode[:fail_cleanup], do: "[ \"$sub\" = 'delete-buffer' ] && exit 1", else: ":"),
      "exit 0",
      ""
    ]

    bin = Path.join(dir, "tmux")
    File.write!(bin, Enum.join(lines, "\n"))
    File.chmod!(bin, 0o700)

    name = :"s3a_tmux_#{c.n}_#{System.unique_integer([:positive])}"

    start_supervised!({AiPair.Tmux, [name: name, tmux_bin: bin, socket_name: "s3a_#{c.n}"]},
      id: {:tmux, name}
    )

    Map.merge(c, %{tmux: name, tmux_log: log, tmux_gate: gate})
  end

  defp unblock(c), do: Task.start(fn -> File.write!(c.tmux_gate, "go\n") end)

  defp verbs(c) do
    c.tmux_log
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&(&1 == "list-panes"))
  end

  defp witness(c), do: Agent.get(c.witness, & &1)

  defp effects(inbox) do
    case File.read(Path.join([inbox, "delivery", "effects.jsonl"])) do
      {:ok, bytes} -> bytes |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      {:error, :enoent} -> []
    end
  end

  defp receipts(inbox) do
    case File.read(Path.join([inbox, "delivery", "receipts.jsonl"])) do
      {:ok, bytes} -> bytes
      {:error, :enoent} -> ""
    end
  end

  defp last_status(inbox, msg) do
    inbox
    |> receipts()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["message_id"] == msg))
    |> List.last()
    |> Map.get("status")
  end

  # payload objects live in <inbox>/delivery/payloads (PayloadStore); temp files are dotfiles,
  # which Path.wildcard/1 does not match
  defp object_count(inbox) do
    inbox
    |> Path.join("delivery/payloads/*")
    |> Path.wildcard()
    |> length()
  end

  defp eventually(fun, deadline_ms \\ 5_000) do
    started = System.monotonic_time(:millisecond)
    poll(fun, started + deadline_ms)
  end

  defp poll(fun, deadline) do
    case fun.() do
      result when result in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline,
          do: flunk("condition not reached"),
          else: retry(fun, deadline)

      result ->
        result
    end
  end

  defp retry(fun, deadline) do
    Process.sleep(20)
    poll(fun, deadline)
  end

  defp id(seed), do: "snd_" <> Base.encode16(:crypto.hash(:sha256, seed), case: :lower)
  defp bytes(seed), do: seed <> " bytes"
end
