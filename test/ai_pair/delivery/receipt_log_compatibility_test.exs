defmodule AiPair.Delivery.ReceiptLogCompatibilityTest do
  @moduledoc """
  Receipt-log version findings F-A and F-B (scope
  CLAUDE-ORRISD-RECEIPT-LOG-VERSION-FINDINGS-SCOPE-r2.org).

    * F-A: at Orrisd 08b7e61c, before the fix, `ReceiptLog` treated a complete,
      unterminated final line as a torn fragment and truncated it during `open/2`; the
      A rows recorded that as RED byte loss. Only a tail that does not decode, or that
      decodes to an own-version object passing full record validation against the
      validated prefix (T1a), may be repaired. T1b, T2, T3 and T4 tails are refused with
      the file bytes unchanged.
    * F-B: at Orrisd 08b7e61c, before the fix, a line with another `schema` or
      `schema_version` was reported as the generic `receipt_log_corrupt`; the B rows
      recorded that as RED on the reason. It must be reported as
      `receipt_log_incompatible`, naming seq, a bounded `found` and the `expected` pair.

  Rows A1-A7, AC3, B1-B3 and B5 are expected to fail before the product change. AC1,
  AC2 (an in-file mirror of the existing decode-error fragment repair) and B4 are
  controls that must pass before and after it.
  """

  use ExUnit.Case, async: true

  alias AiPair.Delivery.{ReceiptLog, ReceiptStore, SystemFs}
  alias AiPair.Test.FaultFs

  @schema "ai-pair/delivery-receipt"
  @other_schema "ai-pair/other-receipt"
  @pane "%receiptlog_compat"
  @payload "sha256:" <> String.duplicate("d4", 32)
  @epoch "ep_" <> String.duplicate("0d", 12)
  @anchor "sha256:" <> Base.encode16(:crypto.hash(:sha256, ""), case: :lower)

  setup do
    inbox =
      Path.join(System.tmp_dir!(), "receiptlog_compat_#{System.unique_integer([:positive])}")

    File.mkdir_p!(inbox)
    on_exit(fn -> File.rm_rf!(inbox) end)
    {:ok, inbox: inbox}
  end

  describe "F-A: a complete unterminated tail is classified, not blindly truncated" do
    test "A1 seq-2 future schema_version, unterminated, refuses as incompatible",
         %{inbox: dir} do
      first = first_line()
      control = seq2(first)
      future = %{control | "schema_version" => 2}
      tail = Jason.encode!(future)
      write_log!(dir, first <> tail)

      refute String.ends_with?(File.read!(log_path(dir)), "\n")
      assert {:ok, %{}} = Jason.decode(tail)
      assert changed_keys(control, future) == ["schema_version"]

      reason = incompatible(2, @schema, 2)
      assert_fa_open_refuses!(dir, reason)
      assert_store_refuses!(dir, reason)
      assert_no_truncate!(dir, reason)
    end

    test "A2 single-line log, future schema_version, no newline anywhere, refuses at seq 1",
         %{inbox: dir} do
      future = %{record(1, @anchor, "only") | "schema_version" => 2}
      write_log!(dir, Jason.encode!(future))

      refute String.contains?(File.read!(log_path(dir)), "\n")

      reason = incompatible(1, @schema, 2)
      assert_fa_open_refuses!(dir, reason)
      assert_no_truncate!(dir, reason)
    end

    test "A3 seq-2 other schema name, unterminated, refuses as incompatible", %{inbox: dir} do
      first = first_line()
      control = seq2(first)
      other = %{control | "schema" => @other_schema}
      tail = Jason.encode!(other)
      write_log!(dir, first <> tail)

      refute String.ends_with?(File.read!(log_path(dir)), "\n")
      assert {:ok, %{}} = Jason.decode(tail)
      assert changed_keys(control, other) == ["schema"]

      reason = incompatible(2, @other_schema, 1)
      assert_fa_open_refuses!(dir, reason)
      assert_store_refuses!(dir, reason)
      assert_no_truncate!(dir, reason)
    end

    a4_rows = [{"string", "1", :string}, {"float", 1.0, :float}, {"null", nil, :null}]

    for {label, value, marker} <- a4_rows do
      test "A4 seq-2 #{label} schema_version, unterminated, refuses with a type marker",
           %{inbox: dir} do
        value = unquote(Macro.escape(value))
        marker = unquote(marker)
        first = first_line()
        tail = Jason.encode!(%{seq2(first) | "schema_version" => value})
        write_log!(dir, first <> tail)

        refute String.ends_with?(File.read!(log_path(dir)), "\n")
        assert {:ok, %{"schema_version" => decoded}} = Jason.decode(tail)
        assert json_type(decoded) == marker, "the decoded version has the intended type"

        reason = incompatible(2, @schema, {:unsupported_type, marker})
        assert_fa_open_refuses!(dir, reason)
        assert_no_truncate!(dir, reason)
      end
    end

    test "A5 T3 unterminated empty object refuses as corrupt", %{inbox: dir} do
      first = first_line()
      write_log!(dir, first <> "{}")

      refute String.ends_with?(File.read!(log_path(dir)), "\n")
      assert {:ok, %{} = empty} = Jason.decode("{}")
      assert map_size(empty) == 0

      reason = {:receipt_log_corrupt, 2}
      assert_fa_open_refuses!(dir, reason)
      assert_no_truncate!(dir, reason)
      assert_store_refuses!(dir, reason)
    end

    test "A6a T1b own-version seq-2 with a wrong chain link, unterminated, refuses as corrupt",
         %{inbox: dir} do
      first = first_line()
      control = seq2(first)
      wrong = digest("not the seq-1 line\n")
      assert wrong != digest(first)
      assert ReceiptLog.valid_hash?(wrong)

      assert_control_opens!(dir, first, control)

      invalid = %{control | "prev_line_sha256" => wrong}
      tail = Jason.encode!(invalid)
      write_log!(dir, first <> tail)

      refute String.ends_with?(File.read!(log_path(dir)), "\n")

      assert {:ok, %{"schema" => @schema, "schema_version" => 1}} = Jason.decode(tail)

      reason = {:receipt_log_corrupt, 2}
      assert_fa_open_refuses!(dir, reason)
      assert_no_truncate!(dir, reason)
      assert_store_refuses!(dir, reason)
    end

    test "A6b T1b own-version seq-2 with an extra key, unterminated, refuses as corrupt",
         %{inbox: dir} do
      first = first_line()
      control = seq2(first)
      invalid = Map.put(control, "extra", "x")
      assert Enum.sort(Map.keys(invalid) -- Map.keys(control)) == ["extra"]
      assert Map.keys(control) -- Map.keys(invalid) == []

      assert_control_opens!(dir, first, control)

      tail = Jason.encode!(invalid)
      write_log!(dir, first <> tail)

      refute String.ends_with?(File.read!(log_path(dir)), "\n")

      assert {:ok, %{"schema" => @schema, "schema_version" => 1}} = Jason.decode(tail)

      reason = {:receipt_log_corrupt, 2}
      assert_fa_open_refuses!(dir, reason)
      assert_no_truncate!(dir, reason)
      assert_store_refuses!(dir, reason)
    end

    a7_rows = [{"number", "42"}, {"array", "[1,2]"}, {"string", ~s("x")}, {"null", "null"}]

    for {label, tail} <- a7_rows do
      test "A7 T4 seq-2 #{label} tail, unterminated, refuses as corrupt", %{inbox: dir} do
        tail = unquote(tail)
        first = first_line()
        write_log!(dir, first <> tail)

        refute String.ends_with?(File.read!(log_path(dir)), "\n")
        assert {:ok, value} = Jason.decode(tail)
        refute is_map(value)
        assert is_nil(value) == (tail == "null"), "only the null tail decodes to nil"

        reason = {:receipt_log_corrupt, 2}
        assert_fa_open_refuses!(dir, reason)
        assert_no_truncate!(dir, reason)
        assert_store_refuses!(dir, reason)
      end
    end

    test "A7 T4 single-line log of a bare number, no newline, refuses at seq 1",
         %{inbox: dir} do
      write_log!(dir, "42")

      refute String.contains?(File.read!(log_path(dir)), "\n")
      assert {:ok, 42} = Jason.decode("42")

      reason = {:receipt_log_corrupt, 1}
      assert_fa_open_refuses!(dir, reason)
      assert_no_truncate!(dir, reason)
    end
  end

  describe "F-A controls" do
    test "AC1 T1a valid own-version seq-2, unterminated, is repaired to seq 1",
         %{inbox: dir} do
      first = first_line()
      valid = seq2(first)
      tail = Jason.encode!(valid)
      write_log!(dir, first <> tail)

      refute String.ends_with?(File.read!(log_path(dir)), "\n")
      assert {:ok, ^valid} = Jason.decode(tail)

      assert_opens!(dir, 1)
      assert File.read!(log_path(dir)) == first, "own-format crash repair truncates the tail"
    end

    test "AC2 mirror: a decode-error torn fragment is still repaired", %{inbox: dir} do
      first = first_line()
      fragment = ~s({"schema":"ai-pair/delivery-receipt","seq":2,"msg_i)
      write_log!(dir, first <> fragment)

      assert {:error, %Jason.DecodeError{}} = Jason.decode(fragment)

      fs = FaultFs.new()
      assert {:ok, log} = ReceiptLog.open(fs, dir)

      try do
        assert log.seq == 1
      after
        ReceiptLog.close(log)
      end

      assert :truncate in FaultFs.ops(fs)
      assert File.read!(log_path(dir)) == first
    end

    test "AC3 the A1 future line WITH its newline refuses with the same reason",
         %{inbox: dir} do
      first = first_line()
      future = %{seq2(first) | "schema_version" => 2}
      write_log!(dir, first <> encode_line(future))

      assert String.ends_with?(File.read!(log_path(dir)), "\n")

      assert_open_refuses!(dir, incompatible(2, @schema, 2))
    end
  end

  describe "F-B: a version mismatch is reported as incompatible" do
    b1_rows = [
      {"schema_version 2", "schema_version", 2, @schema, 2},
      {"schema_version string", "schema_version", "1", @schema, {:unsupported_type, :string}},
      {"schema_version float", "schema_version", 1.0, @schema, {:unsupported_type, :float}},
      {"schema_version null", "schema_version", nil, @schema, {:unsupported_type, :null}},
      {"other schema name", "schema", @other_schema, @other_schema, 1}
    ]

    for {label, key, value, found_schema, found_version} <- b1_rows do
      test "B1 terminated seq-2 #{label} gives the exact incompatible term", %{inbox: dir} do
        key = unquote(key)
        value = unquote(Macro.escape(value))
        first = first_line()
        line = encode_line(Map.put(seq2(first), key, value))
        write_log!(dir, first <> line)

        assert String.ends_with?(File.read!(log_path(dir)), "\n")
        assert decode_line!(line)["prev_line_sha256"] == digest(first)

        reason =
          incompatible(2, unquote(found_schema), unquote(Macro.escape(found_version)))

        assert_open_refuses!(dir, reason)
        assert_store_refuses!(dir, reason)
      end
    end

    test "B2 terminated seq-1 future line gives the incompatible term at seq 1",
         %{inbox: dir} do
      write_log!(dir, encode_line(%{record(1, @anchor, "only") | "schema_version" => 2}))

      assert_open_refuses!(dir, incompatible(1, @schema, 2))
    end

    test "B3a future version with a wrong chain link is incompatible, not corrupt",
         %{inbox: dir} do
      first = first_line()
      wrong = digest("not the seq-1 line\n")
      assert wrong != digest(first)

      line =
        encode_line(%{seq2(first) | "schema_version" => 2, "prev_line_sha256" => wrong})

      write_log!(dir, first <> line)

      assert_open_refuses!(dir, incompatible(2, @schema, 2))
    end

    test "B3b future version with an extra key is incompatible, not corrupt", %{inbox: dir} do
      first = first_line()

      line =
        encode_line(
          seq2(first)
          |> Map.put("schema_version", 2)
          |> Map.put("extra", "x")
        )

      write_log!(dir, first <> line)

      assert_open_refuses!(dir, incompatible(2, @schema, 2))
    end
  end

  describe "F-B controls: no over-classification" do
    test "B4 a v1 line with a broken chain link stays receipt_log_corrupt", %{inbox: dir} do
      first = first_line()
      wrong = digest("not the seq-1 line\n")
      assert wrong != digest(first)
      write_log!(dir, first <> encode_line(%{seq2(first) | "prev_line_sha256" => wrong}))

      assert_open_refuses!(dir, {:receipt_log_corrupt, 2})
    end

    test "B4 a line missing schema stays receipt_log_corrupt", %{inbox: dir} do
      first = first_line()
      write_log!(dir, first <> encode_line(Map.delete(seq2(first), "schema")))

      assert_open_refuses!(dir, {:receipt_log_corrupt, 2})
    end
  end

  describe "F-B bounding of echoed values" do
    test "B5 a 10_000-character schema is unrecognized and not echoed", %{inbox: dir} do
      long = String.duplicate("a", 10_000)
      reason = refused_reason!(dir, "schema", long)

      assert reason == incompatible(2, :unrecognized, 1)
      refute shown(reason) =~ long
      refute shown(reason) =~ binary_part(long, 0, 64)
    end

    test "B5 a schema with an escaped control character is unrecognized and not echoed",
         %{inbox: dir} do
      raw = "ai-pair/\u0001receipt"
      assert Jason.encode!(raw) =~ "\\u0001"
      reason = refused_reason!(dir, "schema", raw)

      assert reason == incompatible(2, :unrecognized, 1)
      refute shown(reason) =~ raw
    end

    test "B5 a 10_000-character schema_version string gets a string marker", %{inbox: dir} do
      long = String.duplicate("b", 10_000)
      reason = refused_reason!(dir, "schema_version", long)

      assert reason == incompatible(2, @schema, {:unsupported_type, :string})
      refute shown(reason) =~ binary_part(long, 0, 64)
    end

    test "B5 a schema_version with an escaped control character gets a string marker",
         %{inbox: dir} do
      raw = "v\u0007v"
      assert Jason.encode!(raw) =~ "\\u0007"
      reason = refused_reason!(dir, "schema_version", raw)

      assert reason == incompatible(2, @schema, {:unsupported_type, :string})
      refute shown(reason) =~ raw
    end

    test "B5 an out-of-range integer schema_version gets an integer_out_of_range marker",
         %{inbox: dir} do
      reason = refused_reason!(dir, "schema_version", 2_000_000)

      assert reason == incompatible(2, @schema, {:unsupported_type, :integer_out_of_range})
      refute shown(reason) =~ "2000000"
    end

    test "B5 an array schema_version gets an array marker", %{inbox: dir} do
      reason = refused_reason!(dir, "schema_version", [7, 7, 7])

      assert reason == incompatible(2, @schema, {:unsupported_type, :array})
      refute shown(reason) =~ "[7, 7, 7]"
    end

    test "B5 an object schema_version gets an object marker", %{inbox: dir} do
      reason = refused_reason!(dir, "schema_version", %{"kk" => "vv"})

      assert reason == incompatible(2, @schema, {:unsupported_type, :object})
      refute shown(reason) =~ "kk"
      refute shown(reason) =~ "vv"
    end
  end

  # ----- helpers -----

  defp incompatible(seq, found_schema, found_version) do
    {:receipt_log_incompatible,
     %{
       seq: seq,
       found: %{schema: found_schema, schema_version: found_version},
       expected: %{schema: @schema, schema_version: 1}
     }}
  end

  defp record(seq, prev, seed) do
    %{
      "schema" => @schema,
      "schema_version" => 1,
      "seq" => seq,
      "prev_line_sha256" => prev,
      "daemon_epoch" => @epoch,
      "message_id" => message_id(seed),
      "pane_id" => @pane,
      "payload_hash" => @payload,
      "status" => "pending",
      "delivery_attempt" => 1
    }
  end

  defp first_line, do: encode_line(record(1, @anchor, "first"))

  # A valid seq-2 successor of `first`: a new id, pending, attempt 1, chained over the
  # real bytes of the seq-1 line including its newline.
  defp seq2(first), do: record(2, digest(first), "second")

  # Writes a terminated seq-2 line carrying `key => value` and returns the refusal.
  defp refused_reason!(dir, key, value) do
    first = first_line()
    write_log!(dir, first <> encode_line(Map.put(seq2(first), key, value)))
    path = log_path(dir)
    before = File.read!(path)

    result = open_result(SystemFs.new(), dir)
    assert {:error, reason} = result
    assert File.read!(path) == before
    reason
  end

  # The same-construction control for A6: the valid seq-2 map, unterminated, opens.
  defp assert_control_opens!(inbox, first, control) do
    dir = Path.join(inbox, "control")
    write_log!(dir, first <> Jason.encode!(control))
    assert_opens!(dir, 1)
  end

  # F-A rows (A1-A7): byte preservation is asserted BEFORE the exact reason, so the
  # current tail truncation is witnessed directly by its own failure, including the
  # zero-length truncation of A2 and the A7 single-line case. Both must hold after
  # the product change.
  defp assert_fa_open_refuses!(dir, reason) do
    path = log_path(dir)
    before = File.read!(path)
    result = open_result(SystemFs.new(), dir)
    after_open = File.read!(path)

    assert after_open == before,
           "F-A byte loss: file changed by open (#{byte_size(before)} bytes before, " <>
             "#{byte_size(after_open)} bytes after)"

    assert result == {:error, reason}, "ReceiptLog.open must refuse with the exact reason"
  end

  defp assert_open_refuses!(dir, reason) do
    path = log_path(dir)
    before = File.read!(path)
    result = open_result(SystemFs.new(), dir)

    assert result == {:error, reason}, "ReceiptLog.open must refuse with the exact reason"
    assert File.read!(path) == before, "a refused log is not repaired or truncated"
  end

  # GenServer.start is unlinked and unregistered, so an unexpected success is stopped.
  defp assert_store_refuses!(dir, reason) do
    path = log_path(dir)
    before = File.read!(path)
    result = GenServer.start(ReceiptStore, inbox: dir)
    with {:ok, pid} <- result, do: GenServer.stop(pid)

    assert result == {:error, reason}, "the store open path must refuse with the exact reason"
    assert File.read!(path) == before, "a refused store start leaves the log bytes unchanged"
  end

  defp assert_no_truncate!(dir, reason) do
    path = log_path(dir)
    before = File.read!(path)
    fs = FaultFs.new()
    result = open_result(fs, dir)

    assert result == {:error, reason}, "the seam open must refuse with the exact reason"
    refute :truncate in FaultFs.ops(fs), "a refusal never reaches the truncate seam"
    assert File.read!(path) == before
  end

  defp open_result(fs, dir) do
    result = ReceiptLog.open(fs, dir)
    with {:ok, log} <- result, do: ReceiptLog.close(log)
    result
  end

  defp assert_opens!(dir, seq) do
    assert {:ok, log} = ReceiptLog.open(SystemFs.new(), dir)

    try do
      assert log.seq == seq
    after
      ReceiptLog.close(log)
    end
  end

  # The full inspect of a reason, as annotate_boot_outcome/1 would render it, unlimited.
  defp shown(reason), do: inspect(reason, limit: :infinity, printable_limit: :infinity)

  defp json_type(value) when is_binary(value), do: :string
  defp json_type(value) when is_float(value), do: :float
  defp json_type(nil), do: :null
  defp json_type(_value), do: :other

  defp changed_keys(old, new) do
    new
    |> Enum.filter(fn {key, value} -> Map.get(old, key) != value end)
    |> Enum.map(fn {key, _value} -> key end)
    |> Enum.sort()
  end

  defp write_log!(dir, bytes) do
    path = log_path(dir)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  defp log_path(dir), do: Path.join([dir, "delivery", "receipts.jsonl"])

  defp encode_line(record), do: Jason.encode!(record) <> "\n"

  defp decode_line!(line), do: line |> String.trim_trailing("\n") |> Jason.decode!()

  defp digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp message_id(seed), do: "snd_" <> Base.encode16(:crypto.hash(:sha256, seed), case: :lower)
end
