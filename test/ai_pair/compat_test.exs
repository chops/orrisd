defmodule AiPair.CompatTest do
  @moduledoc """
  NS-32.M.002 RB-2a RED: the compatibility contract (RB23-INTERFACE-SCOPE-r3).

  `AiPair.Compat.reads/0` declares, per durable-state dimension, the versions this build reads;
  it is the one source the release manifest's "reads" stamp is checked against.
  `AiPair.Compat.observe/1` is a PURE offline parser of an inbox: it opens files read-only,
  never calls the product readers (which repair or truncate), writes nothing, and reports each
  dimension as `{:ok, versions}`, `:absent` or `:unknown`, plus whether an unresolved effect hold
  exists. `AiPair.Compat.compatible?/2` applies an observation to a target's declared reads:
  `:supported`, `{:refused, component, observed, accepted, recipe}` or `:unknown`; a target with
  no declaration (every pre-RB-2 build) is `:unknown`, and so is any `:unknown` dimension.

  The state below is written by the product's own writers (ReceiptStore, EffectJournal and the
  pane-intent envelope encoder), so the parser is held to real bytes.
  """

  use ExUnit.Case, async: false

  alias AiPair.Delivery.{EffectJournal, ReceiptStore, SystemFs}
  alias AiPair.PaneIntentStore.Record

  @dims ~w(effects lineage pane_intent payloads receipts)
  @text "compat fixture input"
  @hash "sha256:" <> Base.encode16(:crypto.hash(:sha256, @text), case: :lower)
  @id "snd_" <> String.duplicate("c", 64)

  setup do
    inbox = Path.join(System.tmp_dir!(), "compat-#{System.unique_integer([:positive])}")
    File.mkdir_p!(inbox)
    on_exit(fn -> File.rm_rf!(inbox) end)
    {:ok, inbox: inbox, pane: "%compat_#{System.unique_integer([:positive])}"}
  end

  test "reads/0 declares exactly the versions this build's readers accept" do
    reads = compat(:reads, [])

    assert Enum.sort(Map.keys(reads)) == Enum.sort(["effects_hold_aware" | @dims])
    assert reads["receipts"] == [1, 2, 3]
    assert reads["pane_intent"] == Enum.sort(Map.keys(Record.schemas()))
    assert Record.version() in reads["pane_intent"]
    assert reads["lineage"] == [1]
    assert reads["effects"] == [1]
    assert reads["effects_hold_aware"] == true
    assert reads["payloads"] == [1]
  end

  test "a fresh inbox observes every dimension as absent and no hold", c do
    obs = compat(:observe, [c.inbox])

    for dim <- @dims, do: assert(obs[dim] == :absent, dim)
    assert obs["effects_hold"] == false
  end

  test "state written by the product's writers is observed with its versions and its hold", c do
    write_state!(c)
    obs = compat(:observe, [c.inbox])

    assert obs["receipts"] == {:ok, [3]}
    assert obs["lineage"] == {:ok, [1]}
    assert obs["pane_intent"] == {:ok, [Record.version()]}
    assert obs["effects"] == {:ok, [1]}
    assert obs["effects_hold"] == true
    assert obs["payloads"] == {:ok, [1]}
  end

  test "observe/1 writes nothing: every file keeps its bytes and mtime", c do
    write_state!(c)
    before = snapshot(c.inbox)

    _ = compat(:observe, [c.inbox])
    assert snapshot(c.inbox) == before
  end

  test "an unterminated receipts tail is unknown and is NOT truncated", c do
    write_state!(c)
    path = Path.join([c.inbox, "delivery", "receipts.jsonl"])
    File.write!(path, ~s({"schema":"ai-pair/delivery-receipt","schema_version":3), [:append])
    bytes = File.read!(path)

    assert compat(:observe, [c.inbox])["receipts"] == :unknown
    assert File.read!(path) == bytes
  end

  test "an unreadable pane-intent file is unknown", c do
    File.write!(Path.join(c.inbox, "pane-attachments.json"), "{not json")
    assert compat(:observe, [c.inbox])["pane_intent"] == :unknown
  end

  test "compatible?/2: supported when every observed version is read, absent counts as nothing" do
    obs = observation(%{"receipts" => {:ok, [2, 3]}, "lineage" => :absent})
    assert compat(:compatible?, [obs, compat(:reads, [])]) == :supported
  end

  test "compatible?/2: a target without a declaration, or an unknown dimension, is unknown" do
    assert compat(:compatible?, [observation(%{}), nil]) == :unknown
    obs = observation(%{"lineage" => :unknown})
    assert compat(:compatible?, [obs, compat(:reads, [])]) == :unknown
  end

  test "compatible?/2: an unread version is refused with component, versions and a recipe" do
    reads = Map.put(compat(:reads, []), "receipts", [1, 2])
    obs = observation(%{"receipts" => {:ok, [3]}})

    assert {:refused, "receipts", [3], [1, 2], recipe} = compat(:compatible?, [obs, reads])
    assert is_binary(recipe) and recipe != ""
  end

  test "compatible?/2: an unresolved effect hold refuses a target that is not hold-aware" do
    reads = Map.put(compat(:reads, []), "effects_hold_aware", false)
    obs = observation(%{"effects" => {:ok, [1]}, "effects_hold" => true})

    assert {:refused, "effects", _, _, _} = compat(:compatible?, [obs, reads])
    assert compat(:compatible?, [obs, compat(:reads, [])]) == :supported
  end

  test "compatible?/2: an unread payload layout is refused" do
    reads = Map.put(compat(:reads, []), "payloads", [])
    obs = observation(%{"payloads" => {:ok, [1]}})

    assert {:refused, "payloads", [1], [], _} = compat(:compatible?, [obs, reads])
  end

  # GREEN rows (RB-2a source review r2): every effect, receipt and lineage line is judged by its
  # module's own rules, and an impossible observation is unknown.
  test "an effect line of an unknown kind makes effects unknown", c do
    write_effects!(c, [begin_record(1), %{"kind" => "pause", "marker_id" => marker(1)}])
    assert compat(:observe, [c.inbox])["effects"] == :unknown
  end

  test "a forged end of an open begin (missing fields) makes effects unknown and is not a clear",
       c do
    write_effects!(c, [begin_record(1), %{"kind" => "end", "marker_id" => marker(1)}])
    obs = compat(:observe, [c.inbox])

    assert obs["effects"] == :unknown
    assert compat(:compatible?, [obs, compat(:reads, [])]) == :unknown
  end

  test "an orphan end, a duplicate begin and a duplicate end each make effects unknown", c do
    for records <- [
          [end_record(1)],
          [begin_record(1), begin_record(1)],
          [begin_record(1), end_record(1), end_record(1)]
        ] do
      write_effects!(c, records)
      assert compat(:observe, [c.inbox])["effects"] == :unknown, inspect(records)
    end
  end

  test "a valid begin and end clear the hold; a valid begin alone holds", c do
    write_effects!(c, [begin_record(1), end_record(1)])
    assert compat(:observe, [c.inbox])["effects"] == {:ok, [1]}
    assert compat(:observe, [c.inbox])["effects_hold"] == false

    write_effects!(c, [begin_record(1)])
    assert compat(:observe, [c.inbox])["effects_hold"] == true
  end

  test "a broken effect chain makes effects unknown", c do
    [first, second] = effect_lines([begin_record(1), end_record(1)])
    File.mkdir_p!(Path.join(c.inbox, "delivery"))
    File.write!(Path.join([c.inbox, "delivery", "effects.jsonl"]), second <> first)
    assert compat(:observe, [c.inbox])["effects"] == :unknown
  end

  test "a receipts line with the right version but missing fields is unknown", c do
    write_state!(c)
    path = Path.join([c.inbox, "delivery", "receipts.jsonl"])
    File.write!(path, ~s({"schema":"ai-pair/delivery-receipt","schema_version":3}\n), [:append])
    assert compat(:observe, [c.inbox])["receipts"] == :unknown
  end

  test "a lineage line with a broken chain is unknown", c do
    write_state!(c)
    path = Path.join([c.inbox, "delivery", "lineage.jsonl"])
    [line | _] = path |> File.read!() |> String.split("\n", trim: true)
    File.write!(path, line <> "\n" <> line <> "\n")
    assert compat(:observe, [c.inbox])["lineage"] == :unknown
  end

  test "compatible?/2: a hold with absent, unknown or empty effects is impossible and unknown" do
    reads = compat(:reads, [])

    for effects <- [:absent, :unknown, {:ok, []}] do
      obs = observation(%{"effects" => effects, "effects_hold" => true})
      assert compat(:compatible?, [obs, reads]) == :unknown, inspect(effects)
    end
  end

  test "a pane-intent file is judged as a whole envelope: version alone, duplicate keys, a bad record or a foreign root are unknown",
       c do
    path = Path.join(c.inbox, "pane-attachments.json")
    valid = envelope([intent_record("%1", c.inbox)])

    for {label, bytes} <- [
          {"version only", ~s({"schema_version":"1.0"})},
          {"duplicate keys",
           ~s({"schema_version":"2.0","schema_version":"2.0","updated_at":"2026-10-07T00:00:00Z","attachments":{}})},
          {"a bad record", envelope([Map.delete(intent_record("%1", c.inbox), "pane_pid")])},
          {"a foreign root", envelope([intent_record("%1", "/elsewhere/inbox")])}
        ] do
      File.write!(path, bytes)
      assert compat(:observe, [c.inbox])["pane_intent"] == :unknown, label
    end

    File.write!(path, valid)
    assert compat(:observe, [c.inbox])["pane_intent"] == {:ok, ["2.0"]}
  end

  # GREEN rows (RB-2a source review r1): structured fail-closed inputs and an OS read denial.
  test "compatible?/2: a malformed or incomplete declaration is unknown" do
    reads = compat(:reads, [])
    obs = observation(%{})

    for bad <- [
          Map.delete(reads, "payloads"),
          Map.put(reads, "receipts", 3),
          Map.put(reads, "effects_hold_aware", "true"),
          Map.put(reads, "extra", [1]),
          [],
          "reads"
        ] do
      assert compat(:compatible?, [obs, bad]) == :unknown, inspect(bad)
    end
  end

  test "compatible?/2: an observation missing a dimension or the hold is unknown" do
    reads = compat(:reads, [])

    assert compat(:compatible?, [Map.delete(observation(%{}), "lineage"), reads]) == :unknown
    assert compat(:compatible?, [Map.delete(observation(%{}), "effects_hold"), reads]) == :unknown
    assert compat(:compatible?, [observation(%{"receipts" => {:ok, 3}}), reads]) == :unknown
  end

  test "an OS read-denied receipts file is unknown and keeps its bytes and mode", c do
    write_state!(c)
    path = Path.join([c.inbox, "delivery", "receipts.jsonl"])
    bytes = File.read!(path)
    File.chmod!(path, 0o000)
    on_exit(fn -> File.chmod(path, 0o600) end)

    # A privileged runner reads through mode 000; then the denial cannot be exercised here.
    if match?({:error, :eacces}, File.read(path)) do
      assert compat(:observe, [c.inbox])["receipts"] == :unknown
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0
    end

    File.chmod!(path, 0o600)
    assert File.read!(path) == bytes
  end

  # apply/3: AiPair.Compat is GREEN's module, absent at the RED base.
  defp compat(fun, args), do: apply(AiPair.Compat, fun, args)

  defp observation(overrides) do
    @dims
    |> Map.new(&{&1, :absent})
    |> Map.put("effects_hold", false)
    |> Map.merge(overrides)
  end

  # Real writers: one admitted and queued receipt (receipts, lineage, a payload object), one
  # effect begin with no end (an unresolved hold), one empty pane-intent envelope.
  defp write_state!(c) do
    store = start_supervised!({ReceiptStore, [inbox: c.inbox]})

    {:ok, {:admitted, %{operation_token: token}}} =
      ReceiptStore.admit(store, @id, c.pane, @hash, self())

    :ok = ReceiptStore.queue(store, @id, token, @text)
    :ok = stop_supervised(ReceiptStore)

    {:ok, journal} = EffectJournal.open(SystemFs.new(), c.inbox)
    {:ok, _marker, journal} = EffectJournal.begin(journal, c.pane, @id, 1, "ai_pair_7")
    :ok = EffectJournal.close(journal)

    File.write!(
      Path.join(c.inbox, "pane-attachments.json"),
      Record.encode_envelope([], DateTime.utc_now())
    )
  end

  defp marker(n), do: "mk_" <> String.pad_leading(Integer.to_string(n), 32, "0")

  defp begin_record(n) do
    %{
      "kind" => "begin",
      "marker_id" => marker(n),
      "pane_id" => "%compat_fx",
      "msg_id" => "snd_" <> String.duplicate("d", 64),
      "attempt" => 1,
      "buffer" => "ai_pair_" <> Integer.to_string(n)
    }
  end

  defp end_record(n), do: %{"kind" => "end", "marker_id" => marker(n), "code" => 0, "cleanup" => 0}

  # Correctly chained journal lines, as EffectJournal writes them.
  defp effect_lines(records) do
    anchor = "sha256:" <> Base.encode16(:crypto.hash(:sha256, ""), case: :lower)

    {lines, _} =
      Enum.map_reduce(records, anchor, fn record, prev ->
        line =
          record
          |> Map.merge(%{"schema" => "ai-pair/paste-effect", "v" => 1, "prev_line_sha256" => prev})
          |> Jason.encode!()
          |> Kernel.<>("\n")

        {line, "sha256:" <> Base.encode16(:crypto.hash(:sha256, line), case: :lower)}
      end)

    lines
  end

  defp write_effects!(c, records) do
    File.mkdir_p!(Path.join(c.inbox, "delivery"))
    File.write!(Path.join([c.inbox, "delivery", "effects.jsonl"]), Enum.join(effect_lines(records)))
  end

  defp envelope(records) do
    Jason.encode!(%{
      "schema_version" => "2.0",
      "updated_at" => "2026-10-07T00:00:00Z",
      "attachments" => Map.new(records, &{&1["pane_id"], &1})
    })
  end

  defp intent_record(pane_id, root) do
    %{
      "schema_version" => "2.0",
      "registration_id" => "reg_" <> String.duplicate("ab", 16),
      "pane_id" => pane_id,
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

  defp snapshot(root) do
    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.map(fn path -> {path, File.read!(path), File.stat!(path, time: :posix).mtime} end)
  end
end
