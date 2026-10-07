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
    {:ok, _marker, journal} = EffectJournal.begin(journal, c.pane, @id, 1, "ai-pair-compat")
    :ok = EffectJournal.close(journal)

    File.write!(
      Path.join(c.inbox, "pane-attachments.json"),
      Record.encode_envelope([], DateTime.utc_now())
    )
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
