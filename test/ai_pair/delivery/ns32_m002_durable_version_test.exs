defmodule AiPair.Delivery.NS32M002DurableVersionTest do
  @moduledoc """
  NS-32.M.002, the Orrisd half of failure control "Silent incompatible continuation
  or unreadable old state fails".

  Two durable stores carry a schema version. Each must refuse a file whose version
  it does not support. It must not continue on it and must not rewrite it, and a
  same-construction file at the supported version must still load.

  ## Receipt log (`lib/ai_pair/delivery/receipt_log.ex:104-106`)

  A valid three-line control log is built here: three `pending` receipts, each
  correctly chained to the digest of the line before it. Each refusal row then
  changes exactly ONE key on ONE line and leaves every other byte of the file
  identical to the control:

    * line 2 `schema_version` set to `2`, to `"1"`, to `1.0` and to `null`;
    * line 2 `schema` changed to another name;
    * line 1 `schema_version` set to `2` (a future version on the first line).

  The changed line is well-formed JSON with the full key set, and it is correctly
  chained: its `prev_line_sha256` is still the digest of the real line before it.
  Every changed line ends with a trailing newline. The row asserts that newline is
  present before any reader opens the file. This matters because an unterminated
  final line is a TAIL, which the reader truncates as a torn write
  (`receipt_log.ex:125-128`). No row here has a line without its newline.

  For each row, both the log reader (`ReceiptLog.open/2`) and the receipt store's
  own open path (`GenServer.start(ReceiptStore, ...)`, unlinked and unregistered)
  must return exactly `{:error, {:receipt_log_corrupt, n}}`, where `n` is the
  changed line. The file bytes must be identical afterwards. The same-construction
  control, which is the same builder with nothing changed, opens at `seq == 3`
  through the reader and starts through the store.

  These rows are PARTIAL refusal witnesses. They show that an incompatible or
  foreign-schema line is refused at the right line and that the file is left
  untouched. The refusal term is today's generic `{:receipt_log_corrupt, seq}`
  (`receipt_log.ex:95`). That term does not tell an operator that the cause is
  a version or schema incompatibility, so it is not an actionable compatibility
  error. The pair tracks that as a separate product fix. If the product later
  returns a more specific term, these exact-term assertions will fail and must be
  updated with it.

  ## Pane intent store (`lib/ai_pair/pane_intent_store.ex`, `record.ex`)

  This extends `test/ai_pair/pane_intent_store_test.exs:1426` without editing it.
  That test asserts only `stage: :schema`. Here each refusal asserts:

    * the exact error: stage, reason, `outcome: :unchanged` and no cleanup errors;
    * that the on-disk bytes are unchanged.

  Rows:

    * envelope `schema_version` set to `"2.0"`, to `"1"` (a string) and to `1`
      (an integer). Each asserts its own exact error. The term comes from
      `lib/ai_pair/pane_intent_store/record.ex:197-203` (`literal/3` gives
      `{"schema_version", {:unsupported, value}}`) and is wrapped by
      `lib/ai_pair/pane_intent_store.ex:398-402` into
      `%{stage: :schema, reason: ..., outcome: :unchanged, cleanup_errors: []}`;
    * a per-record `schema_version` set to `"2.0"` inside an otherwise valid
      envelope at `"1.0"`.

  Each row has a one-key-differs check against its control. Its same-construction
  control, the same builder at `"1.0"`, starts and lists the record.

  Pane ids are built at run time, as `"%" <> Integer.to_string(unique_integer)`,
  so no literal pane id appears in this source. Every pane row asserts that the
  id matches the record grammar `~r/\A%[0-9]+\z/` (`record.ex:40`) before
  using it.

  ## Limits

    * The receipt-log rows are PARTIAL. They prove refusal and byte
      preservation, not an actionable compatibility diagnosis.
    * The tail path is a known open finding and is handled by a separate product
      change. A final line with no trailing newline is truncated as a torn write
      (`receipt_log.ex:125-128`). No row here exercises that path, and nothing
      here endorses the truncation.
    * Orrisd has no generation, upgrade or rollback mechanism for either store.
      This file therefore gives refusal-only evidence: it shows that an
      unsupported version is refused without being rewritten, not that any
      migration exists.
    * This is the Orrisd half of the control only. The Orris journal and
      protocol half is not covered here.
    * Marker version coverage lives elsewhere, in
      `test/ai_pair/pane_restore/marker_test.exs`:
        - `:158-161` holds the malformed-marker rows "version as a string",
          "version as a float" and "version 2";
        - `:337-344` shows that a version-2 marker is
          `{:marker_malformed, raw}` with zero writes.
      The review cited this file as `test/ai_pair/marker_test.exs`; the path at
      main `08b7e61c` is the one above.
  """

  use ExUnit.Case, async: true

  alias AiPair.Delivery.{ReceiptLog, ReceiptStore, SystemFs}
  alias AiPair.PaneIntentStore

  @anchor "sha256:" <> Base.encode16(:crypto.hash(:sha256, ""), case: :lower)

  # ------------------------------------------------------------ receipt log

  describe "receipt log: one changed key on one well-formed, chained line" do
    setup do
      dir = tmp!("ns32_m002_receipts")
      {:ok, dir: dir}
    end

    test "control: the same construction opens through the reader and the store", %{dir: dir} do
      lines = control_lines()
      write_log!(dir, lines)
      assert_terminated!(lines)

      assert {:ok, log} = ReceiptLog.open(SystemFs.new(), dir)

      try do
        assert log.seq == 3
      after
        ReceiptLog.close(log)
      end

      assert {:ok, pid} = GenServer.start(ReceiptStore, inbox: dir)
      GenServer.stop(pid)
    end

    for {name, line_no, key, value} <- [
          {"schema_version 2", 2, "schema_version", 2},
          {~s(schema_version "1"), 2, "schema_version", "1"},
          {"schema_version 1.0", 2, "schema_version", 1.0},
          {"schema_version null", 2, "schema_version", nil},
          {"schema name changed", 2, "schema", "ai-pair/delivery-receipt-v2"},
          {"future version on the first line", 1, "schema_version", 2}
        ] do
      @row {line_no, key, value}

      test "PARTIAL #{name}: refused at line #{line_no} by the reader and the store; bytes unchanged",
           %{dir: dir} do
        # PARTIAL: proves refusal and byte preservation, not an actionable compatibility diagnosis.
        {line_no, key, value} = @row
        control = control_lines()
        changed = change_key(control, line_no, key, value)

        # One key differs, on one line; every other line is byte-identical.
        assert differing_lines(control, changed) == [line_no]
        assert differing_keys(Enum.at(control, line_no - 1), Enum.at(changed, line_no - 1)) == [key]

        # The changed line is well-formed and still correctly chained.
        changed_record = Jason.decode!(Enum.at(changed, line_no - 1))
        assert Enum.sort(Map.keys(changed_record)) == Enum.sort(Map.keys(record_template()))
        assert changed_record["prev_line_sha256"] == prev_digest(changed, line_no)

        # Every line, the changed one included, carries its trailing newline.
        assert_terminated!(changed)

        write_log!(dir, changed)
        before = File.read!(log_path(dir))

        reader = ReceiptLog.open(SystemFs.new(), dir)
        with {:ok, log} <- reader, do: ReceiptLog.close(log)
        assert reader == {:error, {:receipt_log_corrupt, line_no}}
        assert File.read!(log_path(dir)) == before

        store = GenServer.start(ReceiptStore, inbox: dir)
        with {:ok, pid} <- store, do: GenServer.stop(pid)
        assert store == {:error, {:receipt_log_corrupt, line_no}}
        assert File.read!(log_path(dir)) == before
      end
    end
  end

  defp record_template do
    %{
      "schema" => "ai-pair/delivery-receipt",
      "schema_version" => 1,
      "seq" => 0,
      "prev_line_sha256" => @anchor,
      "daemon_epoch" => "ep_" <> hex(12),
      "message_id" => "snd_" <> hex(32),
      "pane_id" => runtime_pane(),
      "payload_hash" => "sha256:" <> hex(32),
      "status" => "pending",
      "delivery_attempt" => 1
    }
  end

  # Three pending receipts for three different messages, each chained to the real
  # bytes of the line before it.
  defp control_lines do
    epoch = "ep_" <> hex(12)
    pane = runtime_pane()

    {lines, _prev} =
      Enum.map_reduce(1..3, @anchor, fn seq, prev ->
        line =
          record_template()
          |> Map.merge(%{
            "seq" => seq,
            "prev_line_sha256" => prev,
            "daemon_epoch" => epoch,
            "pane_id" => pane
          })
          |> Jason.encode!()
          |> Kernel.<>("\n")

        {line, digest(line)}
      end)

    lines
  end

  # Re-encodes line `n` with one key changed and nothing else touched. Later lines
  # are left byte-identical, so the file differs from the control on one line only.
  defp change_key(lines, n, key, value) do
    List.update_at(lines, n - 1, fn line ->
      line |> Jason.decode!() |> Map.put(key, value) |> Jason.encode!() |> Kernel.<>("\n")
    end)
  end

  defp differing_lines(a, b) do
    for {{x, y}, i} <- Enum.with_index(Enum.zip(a, b), 1), x != y, do: i
  end

  defp differing_keys(a, b) do
    {ra, rb} = {Jason.decode!(a), Jason.decode!(b)}
    assert Enum.sort(Map.keys(ra)) == Enum.sort(Map.keys(rb))
    for k <- Enum.sort(Map.keys(ra)), ra[k] !== rb[k], do: k
  end

  defp prev_digest(_lines, 1), do: @anchor
  defp prev_digest(lines, n), do: digest(Enum.at(lines, n - 2))

  defp assert_terminated!(lines) do
    for {line, i} <- Enum.with_index(lines, 1) do
      assert String.ends_with?(line, "\n"), "line #{i} lacks its trailing newline"
      assert :binary.matches(line, "\n") |> length() == 1
    end
  end

  defp log_path(dir), do: Path.join([dir, "delivery", "receipts.jsonl"])

  defp write_log!(dir, lines) do
    File.mkdir_p!(Path.join(dir, "delivery"))
    File.write!(log_path(dir), IO.iodata_to_binary(lines))
  end

  defp digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  # ------------------------------------------------------------ pane intent store

  describe "pane intent store: unsupported version, exact refusal, bytes unchanged" do
    setup do
      root = tmp!("ns32_m002_intent")
      File.chmod!(root, 0o700)
      pane = runtime_pane()
      assert Regex.match?(~r/\A%[0-9]+\z/, pane)
      {:ok, root: root, pane: pane}
    end

    test "control: the same construction at 1.0 starts and lists the record", ctx do
      assert Regex.match?(~r/\A%[0-9]+\z/, ctx.pane)
      seed!(ctx.root, envelope("1.0", %{ctx.pane => intent(ctx.pane, ctx.root, "1.0")}))
      assert {:ok, store} = PaneIntentStore.start_link(root: ctx.root)

      try do
        assert {:ok, [only]} = PaneIntentStore.list(store)
        assert only["pane_id"] == ctx.pane
        assert only["schema_version"] == "1.0"
      after
        GenServer.stop(store)
      end
    end

    for {name, value} <- [{"2.0", "2.0"}, {~s("1" string), "1"}, {"1 integer", 1}] do
      @value value

      test "envelope schema_version #{name}: exact :schema refusal, outcome unchanged, bytes unchanged",
           ctx do
        value = @value
        assert Regex.match?(~r/\A%[0-9]+\z/, ctx.pane)
        rec = %{ctx.pane => intent(ctx.pane, ctx.root, "1.0")}
        control = envelope("1.0", rec)
        changed = envelope(value, rec)
        assert differing_keys(control, changed) == ["schema_version"]

        seed!(ctx.root, changed)
        before = File.read!(state_path(ctx.root))

        assert PaneIntentStore.start_link(root: ctx.root) ==
                 {:error,
                  %{
                    stage: :schema,
                    reason: {"schema_version", {:unsupported, value}},
                    outcome: :unchanged,
                    cleanup_errors: []
                  }}

        assert File.read!(state_path(ctx.root)) == before
      end
    end

    test "record schema_version 2.0 inside a 1.0 envelope: exact refusal, bytes unchanged", ctx do
      assert Regex.match?(~r/\A%[0-9]+\z/, ctx.pane)
      control_rec = intent(ctx.pane, ctx.root, "1.0")
      changed_rec = intent(ctx.pane, ctx.root, "2.0")

      assert differing_keys(Jason.encode!(control_rec), Jason.encode!(changed_rec)) == [
               "schema_version"
             ]

      control = envelope("1.0", %{ctx.pane => control_rec})
      changed = envelope("1.0", %{ctx.pane => changed_rec})
      assert differing_keys(control, changed) == ["attachments"]

      seed!(ctx.root, changed)
      before = File.read!(state_path(ctx.root))

      assert PaneIntentStore.start_link(root: ctx.root) ==
               {:error,
                %{
                  stage: :schema,
                  reason: {:attachments, ctx.pane, {"schema_version", {:unsupported, "2.0"}}},
                  outcome: :unchanged,
                  cleanup_errors: []
                }}

      assert File.read!(state_path(ctx.root)) == before
    end
  end

  defp intent(pane, root, version) do
    %{
      "schema_version" => version,
      "pane_id" => pane,
      "agent" => "claude_code",
      "classifier" => "fingerprint:claude_code",
      "project" => "demo",
      "project_dir" => "/workspace/demo",
      "project_inbox" => root,
      "tmux_session" => "ai-pair/demo",
      "session_gen" => "2",
      "cwd" => "/workspace/demo",
      "command" => "claude",
      "pane_pid" => 4242,
      "updated_at" => "2026-09-11T00:00:00Z"
    }
  end

  defp envelope(version, attachments) do
    Jason.encode!(%{
      "schema_version" => version,
      "updated_at" => "2026-09-11T00:00:00Z",
      "attachments" => attachments
    })
  end

  defp state_path(root), do: Path.join([root, "state", "pane-attachments.json"])

  defp seed!(root, contents) do
    state = Path.join(root, "state")
    File.mkdir_p!(state)
    File.chmod!(state, 0o700)
    File.write!(state_path(root), contents)
    File.chmod!(state_path(root), 0o600)
  end

  # ------------------------------------------------------------ shared

  defp runtime_pane, do: "%" <> Integer.to_string(System.unique_integer([:positive]))

  defp hex(bytes), do: Base.encode16(:crypto.strong_rand_bytes(bytes), case: :lower)

  # Both stores' rows use the same canonical (symlink-resolved) temp root.
  defp tmp!(prefix) do
    dir = Path.join(canonical_tmp(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # The intent store refuses a root with a symlinked ancestor, so resolve them.
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
end
