defmodule AiPair.Delivery.NS42TerminalCoordinatesTest do
  @moduledoc """
  NS-42.C.007, producer side: a terminal receipt has immutable coordinates.

  `ns42_producer_conformance_test.exs` (rule 7) closes the status-edge set, and
  `receipt_store_test.exs` asserts single fields of a finalized receipt. Neither binds
  the COMPLETE coordinate tuple of a terminal receipt, and neither shows that changing
  one coordinate other than the status is refused, on the write path or at open.

  The tuple, as the product defines it:

    * `ReceiptStore.receipt()` (`receipt_store.ex:21-27`) and `ReceiptLog.view/1`
      (`receipt_log.ex:67-75`): `message_id`, `pane_id`, `payload_hash`, `status`,
      `delivery_attempt`. These five are the receipt view every caller is served.
    * `ReceiptLog` `@fields` (`receipt_log.ex:8`) and `append/3` (`receipt_log.ex:35-47`):
      the persisted record adds `schema`, `schema_version`, `seq`, `prev_line_sha256`
      and `daemon_epoch`. `seq` and `prev_line_sha256` place the record in the chain;
      `daemon_epoch` names the boot that wrote it.
    * Identity is pinned on admission (`receipt_store.ex:215-222`) and on replay
      (`receipt_log.ex:116-123`, `same_identity`); the attempt only advances from
      `not_delivered` (`receipt_store.ex:215-216`, `receipt_log.ex:121-122`).
    * ADR-0003 "Durable Record": "Records are appended, never rewritten to change a
      prior outcome", and "Receipt identity never changes across attempts".

  Every row here asserts behaviour that is already present. No product source changes.
  """

  use ExUnit.Case, async: true

  alias AiPair.Delivery.{ReceiptLog, ReceiptStore, SystemFs}

  @pane "%ns42_c007"
  @other_pane "%ns42_c007_other"
  @payload "sha256:" <> String.duplicate("c7", 32)
  @other_payload "sha256:" <> String.duplicate("7c", 32)
  @epoch "ep_" <> String.duplicate("0c", 12)
  @anchor "sha256:" <> Base.encode16(:crypto.hash(:sha256, ""), case: :lower)

  @statuses ~w(pending queued delivered not_delivered ambiguous)
  @terminal ~w(delivered not_delivered ambiguous)
  @pending_successors ~w(queued delivered not_delivered ambiguous)

  # The five coordinates of the receipt view (`receipt_store.ex:21-27`).
  @coordinates [:message_id, :pane_id, :payload_hash, :status, :delivery_attempt]

  # The closed key set of one persisted record (`receipt_log.ex:8`), written out here
  # rather than read from the module so the rows compare an independent statement.
  @record_fields ~w(schema schema_version seq prev_line_sha256 daemon_epoch
                    message_id pane_id payload_hash status delivery_attempt)

  setup do
    inbox = Path.join(System.tmp_dir!(), "ns42_c007_#{System.unique_integer([:positive])}")

    File.mkdir_p!(inbox)
    on_exit(fn -> File.rm_rf!(inbox) end)
    {:ok, inbox: inbox}
  end

  describe "(a) a terminal receipt binds its complete coordinate tuple" do
    for status <- @terminal do
      test "#{status}: the served view, the persisted record and a reload carry one tuple",
           %{inbox: inbox} do
        status = unquote(status)
        store = start_store!(inbox, :first)
        id = message_id("bound-#{status}")
        token = admit!(store, id).operation_token
        assert :ok = ReceiptStore.transition(store, id, token, status)

        expected = tuple(id, status)

        assert {:ok, served} = reconcile(store, id)

        assert Map.take(served, @coordinates) == expected,
               "the served receipt view must be exactly the bound tuple"

        assert Enum.sort(Map.keys(served)) == Enum.sort([:outcome | @coordinates]),
               "no coordinate may be missing from, or added to, the served view"

        epoch = ReceiptStore.daemon_epoch(store)
        path = ReceiptStore.path(store)
        assert [first_line, terminal_line] = lines(path)
        terminal = decode_line!(terminal_line)

        assert Enum.sort(Map.keys(terminal)) == Enum.sort(@record_fields)

        assert terminal == %{
                 "schema" => "ai-pair/delivery-receipt",
                 "schema_version" => 1,
                 "seq" => 2,
                 "prev_line_sha256" => digest(first_line),
                 "daemon_epoch" => epoch,
                 "message_id" => id,
                 "pane_id" => @pane,
                 "payload_hash" => @payload,
                 "status" => status,
                 "delivery_attempt" => 1
               }

        assert ReceiptLog.view(terminal) == expected

        before = File.read!(path)
        :ok = stop_store(store)
        second = start_store!(inbox, :second)

        refute ReceiptStore.daemon_epoch(second) == epoch

        assert File.read!(path) == before,
               "a restart re-stamps only unresolved attempts; a terminal record is neither " <>
                 "re-appended nor re-stamped with the new epoch"

        assert {:ok, reloaded} = reconcile(second, id)
        assert Map.take(reloaded, @coordinates) == expected
      end
    end

    # Assertion-shape control: it shows the comparison detects a one-coordinate
    # difference. It is not mutation evidence; the rows above carry that.
    test "control: the tuple comparison fails when any single coordinate differs" do
      bound = tuple(message_id("control-tuple"), "delivered")
      changes = one_coordinate_changes(bound)

      # Four identity/attempt changes plus the four other statuses.
      assert length(changes) == 8

      for {key, value} <- changes do
        variant = Map.put(bound, key, value)

        assert_raise ExUnit.AssertionError, fn ->
          assert Map.take(variant, @coordinates) == bound
        end
      end
    end
  end

  describe "(b) a write that would change one coordinate of a terminal receipt is refused" do
    for status <- @terminal do
      test "#{status}: every write entry point leaves the tuple and the log untouched",
           %{inbox: inbox} do
        status = unquote(status)
        store = start_store!(inbox)
        id = message_id("write-#{status}")
        owner = spawn_owner()
        token = admit!(store, id, owner).operation_token
        assert :ok = ReceiptStore.transition(store, id, token, status)

        expected = tuple(id, status)
        path = ReceiptStore.path(store)
        before = File.read!(path)

        # status: the attempt's own token still authorizes it, so the refusal is the
        # edge rule, by name, for every target in the vocabulary.
        for target <- @statuses do
          assert ReceiptStore.transition(store, id, token, target) ==
                   {:error, {:illegal_transition, status, target}},
                 "#{status} -> #{target} must be refused as an illegal transition"
        end

        # pane_id and payload_hash: the same id with one identity coordinate changed is
        # a conflict that reports the bound tuple, not a new or rewritten record.
        assert {:error, {:conflict, pane_conflict}} =
                 ReceiptStore.admit(store, id, @other_pane, @payload, owner)

        assert pane_conflict == expected

        assert {:error, {:conflict, hash_conflict}} =
                 ReceiptStore.admit(store, id, @pane, @other_payload, owner)

        assert hash_conflict == expected

        # delivery_attempt: only proven non-delivery opens another attempt. Delivered and
        # ambiguous may already have reached the pane, so the same identity is a duplicate.
        if status != "not_delivered" do
          assert {:ok, {:duplicate, duplicate}} =
                   ReceiptStore.admit(store, id, @pane, @payload, owner)

          assert duplicate == expected
        end

        assert File.read!(path) == before,
               "no refused write may append, rewrite or truncate the log"

        assert {:ok, served} = reconcile(store, id)
        assert Map.take(served, @coordinates) == expected

        # message_id: no write entry point can re-key a receipt, so there is nothing to
        # refuse. An unrelated admission leaves the prior bytes intact as a prefix.
        other = message_id("other-#{status}")
        assert %{delivery_attempt: 1} = admit!(store, other, owner)
        assert String.starts_with?(File.read!(path), before)
        assert {:ok, still} = reconcile(store, id)
        assert Map.take(still, @coordinates) == expected

        if status == "not_delivered" do
          # The one legal successor of a terminal attempt is a NEW attempt. It is
          # appended; the terminal attempt-1 record is kept byte for byte, and the
          # attempt-1 token can no longer finalize anything.
          assert %{delivery_attempt: 2} = admit!(store, id, owner)
          assert String.starts_with?(File.read!(path), before)

          assert ReceiptStore.transition(store, id, token, "delivered") ==
                   {:error, {:stale_operation_token, 1, 2}}

          assert [_pending, terminal_line | _] = lines(path)
          assert ReceiptLog.view(decode_line!(terminal_line)) == expected
        end
      end
    end

    # Assertion-shape control: it shows the byte comparison detects an accepted write.
    # It is not mutation evidence; the rows above carry that.
    test "control: the byte comparison fails when a write is accepted", %{inbox: inbox} do
      store = start_store!(inbox)
      id = message_id("control-accepted-write")
      token = admit!(store, id).operation_token
      path = ReceiptStore.path(store)
      before = File.read!(path)

      # pending -> delivered is a legal edge, so this write is accepted and appended.
      assert :ok = ReceiptStore.transition(store, id, token, "delivered")

      assert_raise ExUnit.AssertionError, fn ->
        assert File.read!(path) == before
      end
    end
  end

  describe "(c) a hand-written line contradicting one terminal coordinate is refused at open" do
    test "control: the hand-written pending and terminal lines open and read back the tuple",
         %{inbox: inbox} do
      for status <- @terminal do
        dir = Path.join(inbox, "control-#{status}")
        {lines, expected} = hand_written_terminal(status)
        assert_chain!(lines)
        write_log!(dir, lines)

        assert {:ok, log} = ReceiptLog.open(SystemFs.new(), dir)

        try do
          assert log.seq == 2
          assert ReceiptLog.view(log.entries[expected.message_id]) == expected
        after
          ReceiptLog.close(log)
        end
      end
    end

    for status <- @terminal do
      test "#{status}: control: a legal seq-3 successor of the terminal line opens",
           %{inbox: inbox} do
        status = unquote(status)
        {lines, _expected} = hand_written_terminal(status)

        # A fresh id opened as pending at attempt 1. It differs from the refused
        # message_id row below ONLY in its status, which isolates that row's cause.
        fresh = message_id("fresh-after-#{status}")
        open_fresh = fn record -> %{record | "message_id" => fresh, "status" => "pending"} end
        successors = [{"fresh", open_fresh} | legal_retry(status)]

        for {label, edit} <- successors do
          dir = Path.join(inbox, "legal-#{status}-#{label}")
          write_log!(dir, lines ++ [forge_after(lines, edit)])

          # Same helper, same position as the refusal rows, and the log opens: the
          # refusals are not "nothing is accepted after a terminal line".
          assert_opens!(dir, 3)
          assert_raise ExUnit.AssertionError, fn -> assert_refused_at_open!(dir, 3) end
        end
      end
    end

    for status <- @terminal do
      test "#{status}: each successor contradicting one coordinate is refused at seq 3",
           %{inbox: inbox} do
        status = unquote(status)
        {lines, expected} = hand_written_terminal(status)
        terminal_line = List.last(lines)
        terminal = decode_line!(terminal_line)

        changes = one_coordinate_changes(expected)
        assert length(changes) == 8

        for {{field, value}, index} <- Enum.with_index(changes) do
          key = Atom.to_string(field)
          dir = Path.join(inbox, "#{status}-#{index}")
          tampered = forge_after(lines, &Map.put(&1, key, value))
          record = decode_line!(tampered)

          # The tampered line is a faithful continuation in every respect but one
          # coordinate: valid JSON, the closed key set, valid grammars, the next seq,
          # and a chain link recomputed over the exact terminal line bytes.
          assert Enum.sort(Map.keys(record)) == Enum.sort(@record_fields)
          assert well_formed?(record), "#{key}: the tampered line must be well formed"
          assert record["seq"] == 3
          assert record["prev_line_sha256"] == digest(terminal_line)
          assert changed_keys(terminal, record) == Enum.sort(["prev_line_sha256", "seq", key])
          assert Map.fetch!(record, key) == value
          assert_chain!(lines ++ [tampered])

          write_log!(dir, lines ++ [tampered])

          # The product reports only {:receipt_log_corrupt, seq} (receipt_log.ex:95),
          # whichever conjunct of valid_record?/2 failed. Attribution to the history
          # rule (history_valid?/2) rests on the assertions above eliminating every
          # other conjunct: key set, schema, grammars, seq and chain link.
          #
          # The message_id variant is not a re-key (the product has no re-key
          # operation): it states that a FIRST record under a new id cannot be
          # terminal (receipt_log.ex:114). Its control above differs only in status.
          assert_refused_at_open!(dir, 3)
          assert_store_refuses!(dir, 3, "#{status}: #{label(field)}")
        end
      end
    end

    for status <- @terminal do
      test "#{status}: an in-place rewrite of an identity coordinate is refused at seq 2",
           %{inbox: inbox} do
        status = unquote(status)
        {[pending_line, _terminal_line], expected} = hand_written_terminal(status)

        identity = Enum.reject(one_coordinate_changes(expected), &match?({:status, _}, &1))
        identity_fields = [:message_id, :pane_id, :payload_hash, :delivery_attempt]
        assert Enum.map(identity, &elem(&1, 0)) == identity_fields

        for {{field, value}, index} <- Enum.with_index(identity) do
          key = Atom.to_string(field)
          dir = Path.join(inbox, "in-place-#{status}-#{index}")

          # The terminal line itself is replaced: nothing follows it, so no later hash
          # has to be recomputed, and its own link to the pending line stays correct.
          rewritten =
            forge_after([pending_line], &(&1 |> Map.put("status", status) |> Map.put(key, value)))

          record = decode_line!(rewritten)
          assert well_formed?(record), "#{key}: the rewritten line must be well formed"
          assert record["seq"] == 2
          assert_chain!([pending_line, rewritten])

          write_log!(dir, [pending_line, rewritten])
          assert_refused_at_open!(dir, 2)
        end
      end
    end

    test "characterisation: an in-place final status rewrite to a legal outcome opens",
         %{inbox: inbox} do
      # KNOWN LIMITATION, pinned rather than hidden. ADR-0003 "Durable Record": "This chain
      # is not authentication against an attacker who can rewrite the entire log." The
      # final line can be replaced by any other legal successor of `pending`, because no
      # later line binds its bytes. Whether NS-42.C.007 must go further is an owner
      # decision; this row changes if the product ever detects it.
      for status <- @terminal, other <- @pending_successors, other != status do
        {[pending_line, _terminal_line], expected} = hand_written_terminal(status)
        dir = Path.join(inbox, "undetected-#{status}-#{other}")
        rewritten = forge_after([pending_line], &Map.put(&1, "status", other))
        write_log!(dir, [pending_line, rewritten])

        assert {:ok, log} = ReceiptLog.open(SystemFs.new(), dir)

        try do
          assert ReceiptLog.view(log.entries[expected.message_id]).status == other
        after
          ReceiptLog.close(log)
        end
      end
    end
  end

  # ===== helpers =====

  defp tuple(id, status) do
    %{
      message_id: id,
      pane_id: @pane,
      payload_hash: @payload,
      status: status,
      delivery_attempt: 1
    }
  end

  # Each entry changes exactly one coordinate of `view` to a well-formed other value.
  defp one_coordinate_changes(view) do
    identity = [
      message_id: message_id("another-" <> view.message_id),
      pane_id: @other_pane,
      payload_hash: @other_payload,
      delivery_attempt: view.delivery_attempt + 1
    ]

    statuses = for other <- @statuses, other != view.status, do: {:status, other}
    identity ++ statuses
  end

  # A pending line and its terminal successor, written by hand with a correct chain.
  defp hand_written_terminal(status) do
    id = message_id("hand-written-#{status}")

    pending = %{
      "schema" => "ai-pair/delivery-receipt",
      "schema_version" => 1,
      "seq" => 1,
      "prev_line_sha256" => @anchor,
      "daemon_epoch" => @epoch,
      "message_id" => id,
      "pane_id" => @pane,
      "payload_hash" => @payload,
      "status" => "pending",
      "delivery_attempt" => 1
    }

    first = encode_line(pending)

    terminal =
      encode_line(%{pending | "seq" => 2, "prev_line_sha256" => digest(first), "status" => status})

    {[first, terminal], tuple(id, status)}
  end

  # Appends one line derived from the last line: the edit is applied, then the seq and
  # the chain link are recomputed from the real tail bytes.
  defp forge_after(lines, edit) do
    last_line = List.last(lines)
    last = decode_line!(last_line)

    last
    |> edit.()
    |> Map.put("seq", last["seq"] + 1)
    |> Map.put("prev_line_sha256", digest(last_line))
    |> encode_line()
  end

  defp assert_refused_at_open!(dir, seq) do
    path = log_path(dir)
    before = File.read!(path)
    result = ReceiptLog.open(SystemFs.new(), dir)

    # An unexpectedly accepted log still has its handle released before the assertion.
    with {:ok, log} <- result, do: ReceiptLog.close(log)

    assert result == {:error, {:receipt_log_corrupt, seq}},
           "the reader must refuse the log at exactly seq #{seq}"

    assert File.read!(path) == before, "a refused complete line is not repaired or truncated"
  end

  # The store's own open path refuses the log with the exact reason. GenServer.start
  # is unlinked and unregistered, so an unexpected success is stopped, not leaked.
  defp assert_store_refuses!(dir, seq, message) do
    result = GenServer.start(ReceiptStore, inbox: dir)
    with {:ok, pid} <- result, do: GenServer.stop(pid)
    assert result == {:error, {:receipt_log_corrupt, seq}}, message
  end

  defp assert_opens!(dir, seq) do
    assert {:ok, log} = ReceiptLog.open(SystemFs.new(), dir)

    try do
      assert log.seq == seq
    after
      ReceiptLog.close(log)
    end
  end

  # The one legal successor that reuses a terminal id: a retry after proven non-delivery.
  defp legal_retry("not_delivered") do
    retry = fn record -> %{record | "status" => "pending", "delivery_attempt" => 2} end
    [{"retry", retry}]
  end

  defp legal_retry(_status), do: []

  defp label(:message_id), do: "a first record under a new id cannot be terminal"
  defp label(field), do: "a successor may not change #{field}"

  # Duplicates the private epoch grammar at receipt_log.ex:108; the product check is
  # not public, so the rows restate it.
  defp well_formed?(record) do
    Enum.all?([
      record["schema"] == "ai-pair/delivery-receipt",
      record["schema_version"] === 1,
      is_binary(record["daemon_epoch"]),
      Regex.match?(~r/\Aep_[0-9a-f]{24}\z/, record["daemon_epoch"]),
      ReceiptLog.valid_id?(record["message_id"]),
      ReceiptLog.valid_pane?(record["pane_id"]),
      ReceiptLog.valid_hash?(record["payload_hash"]),
      record["status"] in @statuses,
      is_integer(record["delivery_attempt"])
    ])
  end

  defp changed_keys(old, new) do
    new
    |> Enum.filter(fn {key, value} -> Map.get(old, key) != value end)
    |> Enum.map(fn {key, _value} -> key end)
    |> Enum.sort()
  end

  defp assert_chain!(lines) do
    Enum.reduce(lines, @anchor, fn line, expected_prev ->
      assert decode_line!(line)["prev_line_sha256"] == expected_prev
      digest(line)
    end)
  end

  defp write_log!(dir, lines) do
    path = log_path(dir)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.join(lines))
  end

  defp log_path(dir), do: Path.join([dir, "delivery", "receipts.jsonl"])

  defp lines(path), do: path |> File.read!() |> String.split(~r/(?<=\n)/, trim: true)

  defp encode_line(record), do: Jason.encode!(record) <> "\n"

  defp decode_line!(line), do: line |> String.trim_trailing("\n") |> Jason.decode!()

  defp digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp message_id(seed),
    do: "snd_" <> Base.encode16(:crypto.hash(:sha256, seed), case: :lower)

  defp start_store!(inbox, id \\ :store) do
    {:ok, pid} = start_store(inbox, id)
    pid
  end

  defp start_store(inbox, id) do
    start_supervised(
      Supervisor.child_spec({ReceiptStore, inbox: inbox}, id: id, restart: :temporary)
    )
  end

  defp stop_store(pid) do
    ref = Process.monitor(pid)
    :ok = GenServer.stop(pid, :normal, 1_000)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      1_000 -> flunk("the store under test never went down")
    end
  end

  defp admit!(store, id, owner \\ nil) do
    {:ok, {:admitted, admission}} =
      ReceiptStore.admit(store, id, @pane, @payload, owner || self())

    admission
  end

  defp reconcile(store, id), do: ReceiptStore.reconcile(store, id, @pane, @payload, wait_ms: 0)

  defp spawn_owner do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end
end
