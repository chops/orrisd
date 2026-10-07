defmodule AiPair.Delivery.EffectJournalTest do
  @moduledoc """
  NS-15.G.003 S3a: the effect journal's own contract (scope r12, "Effect journal"):
  uncleared begins hold, residuals survive compaction, compaction is canonical and
  idempotent, the writer never appends what the boot validator refuses, a torn tail is
  truncated, any other invalid line refuses with the file unchanged, and a failed
  compaction leaves no temp file behind.
  """

  use ExUnit.Case, async: true

  alias AiPair.Delivery.{EffectJournal, SystemFs}
  alias AiPair.Test.FaultFs

  @schema "ai-pair/paste-effect"
  @anchor "sha256:" <> Base.encode16(:crypto.hash(:sha256, ""), case: :lower)
  @pane "%" <> "ej"

  setup do
    inbox = Path.join(System.tmp_dir!(), "effect-journal-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(inbox, "delivery"))
    on_exit(fn -> File.rm_rf!(inbox) end)
    {:ok, inbox: inbox, path: Path.join([inbox, "delivery", "effects.jsonl"])}
  end

  defp id(seed), do: "snd_" <> Base.encode16(:crypto.hash(:sha256, seed), case: :lower)
  defp open!(inbox, fs \\ SystemFs.new()), do: {:ok, _} = EffectJournal.open(fs, inbox)

  defp reopen(j, inbox) do
    :ok = EffectJournal.close(j)
    EffectJournal.open(SystemFs.new(), inbox)
  end

  test "E1 a finished transaction leaves nothing to hold after a reopen", c do
    {:ok, j} = open!(c.inbox)
    {:ok, m, j} = EffectJournal.begin(j, @pane, id("e1"), 1, "ai_pair_1")
    {:ok, j} = EffectJournal.finish(j, m, 0, nil)

    {:ok, j} = reopen(j, c.inbox)
    assert EffectJournal.unresolved(j) == []
    assert File.read!(c.path) == ""
  end

  test "E2 an uncleared begin holds its pane across reopens; compaction is idempotent", c do
    {:ok, j} = open!(c.inbox)
    {:ok, _m, j} = EffectJournal.begin(j, @pane, id("e2"), 1, "ai_pair_2")

    {:ok, j} = reopen(j, c.inbox)
    assert EffectJournal.unresolved(j) == [@pane]
    first = File.read!(c.path)

    {:ok, j} = reopen(j, c.inbox)
    assert File.read!(c.path) == first
    assert EffectJournal.unresolved(j) == [@pane]
  end

  test "E3 the writer refuses inconsistent ends and duplicate residuals without appending", c do
    {:ok, j} = open!(c.inbox)
    {:ok, m, j} = EffectJournal.begin(j, @pane, id("e3"), 1, "ai_pair_3")
    before = File.read!(c.path)

    assert {:error, :inconsistent_end} = EffectJournal.finish(j, m, 1, 1)
    assert {:error, :invalid_end} = EffectJournal.finish(j, m, 256, nil)
    assert File.read!(c.path) == before

    {:ok, j} = EffectJournal.residual(j, m)
    after_residual = File.read!(c.path)
    assert {:error, :duplicate_residual} = EffectJournal.residual(j, m)
    assert {:error, :inconsistent_end} = EffectJournal.finish(j, m, 1, nil)
    assert {:error, :inconsistent_end} = EffectJournal.finish(j, m, 1, 0)
    assert File.read!(c.path) == after_residual

    {:ok, j} = EffectJournal.finish(j, m, 1, 1)
    {:ok, j} = reopen(j, c.inbox)
    assert [%{buffer: "ai_pair_3", msg_id: msg, attempt: 1}] = EffectJournal.residuals(j)
    assert msg == id("e3")
    assert Enum.map(lines(c.path), & &1["kind"]) == ["retained"]
  end

  test "E4 boot validation requires a residual exactly when the cleanup failed", c do
    begin = begin_record("e4", "mk_" <> String.duplicate("a", 32), "ai_pair_4")
    residual = %{begin | "kind" => "residual"}
    end_ok = %{"kind" => "end", "marker_id" => begin["marker_id"], "code" => 1, "cleanup" => 1}

    write_chain!(c.path, [begin, residual, end_ok])
    assert {:ok, _} = EffectJournal.open(SystemFs.new(), c.inbox)

    for {records, bad_line} <- [
          {[begin, residual, %{end_ok | "cleanup" => nil}], 3},
          {[begin, residual, %{end_ok | "cleanup" => 0}], 3},
          {[begin, end_ok], 2}
        ] do
      write_chain!(c.path, records)
      bytes = File.read!(c.path)

      assert {:error, {:effect_journal_corrupt, ^bad_line}} =
               EffectJournal.open(SystemFs.new(), c.inbox)

      assert File.read!(c.path) == bytes
    end
  end

  test "E5 a torn tail is truncated; a corrupt complete line refuses with the file unchanged", c do
    begin = begin_record("e5", "mk_" <> String.duplicate("b", 32), "ai_pair_5")
    write_chain!(c.path, [begin])
    File.write!(c.path, File.read!(c.path) <> ~s({"schema":"ai-pa))
    assert {:ok, j} = EffectJournal.open(SystemFs.new(), c.inbox)
    assert EffectJournal.unresolved(j) == [@pane]
    :ok = EffectJournal.close(j)

    File.write!(c.path, File.read!(c.path) <> ~s({"schema":"#{@schema}","v":1,"kind":"nonsense"}\n))
    bytes = File.read!(c.path)
    assert {:error, {:effect_journal_corrupt, 2}} = EffectJournal.open(SystemFs.new(), c.inbox)
    assert File.read!(c.path) == bytes
  end

  test "E6 a compaction that fails after creating its temp closes and removes it", c do
    # On an empty inbox the first chmod, write and sync of open/2 are the compaction temp's
    # (the journal itself is opened and chmodded only after the rename).
    for op <- [:chmod, :write, :sync] do
      fs = FaultFs.new()
      FaultFs.inject(fs, op, 1, {:error, :eio})

      assert {:error, _} = EffectJournal.open(fs, c.inbox), inspect(op)
      assert FaultFs.count(fs, op) >= 1, "#{op} was reached and failed"
      assert Enum.any?(FaultFs.trace(fs), &compact_call?/1), "the temp was created first"
      refute File.exists?(c.path <> ".compact"), inspect(op)
      refute File.exists?(c.path), "no journal was renamed into place"
    end
  end

  test "E7 residuals are bounded at 256; the 257th is refused without appending", c do
    {:ok, j} = open!(c.inbox)

    j =
      Enum.reduce(1..256, j, fn n, j ->
        {:ok, m, j} = EffectJournal.begin(j, @pane, id("e7-#{n}"), 1, "ai_pair_#{n}")
        {:ok, j} = EffectJournal.residual(j, m)
        {:ok, j} = EffectJournal.finish(j, m, 1, 1)
        j
      end)

    assert EffectJournal.residual_full?(j)
    {:ok, m, j} = EffectJournal.begin(j, @pane, id("e7-x"), 1, "ai_pair_999")
    before = File.read!(c.path)
    assert {:error, :residual_capacity_full} = EffectJournal.residual(j, m)
    assert File.read!(c.path) == before
  end

  defp compact_call?({:open_exclusive, [path]}), do: String.ends_with?(path, ".compact")
  defp compact_call?(_entry), do: false

  defp begin_record(seed, marker, buffer) do
    %{
      "kind" => "begin",
      "marker_id" => marker,
      "pane_id" => @pane,
      "msg_id" => id(seed),
      "attempt" => 1,
      "buffer" => buffer
    }
  end

  defp write_chain!(path, records) do
    {lines, _} =
      Enum.map_reduce(records, @anchor, fn r, prev ->
        line =
          Jason.encode!(Map.merge(r, %{"schema" => @schema, "v" => 1, "prev_line_sha256" => prev})) <>
            "\n"

        {line, "sha256:" <> Base.encode16(:crypto.hash(:sha256, line), case: :lower)}
      end)

    File.write!(path, Enum.join(lines))
  end

  defp lines(path),
    do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
end
