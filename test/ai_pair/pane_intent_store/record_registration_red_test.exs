defmodule AiPair.PaneIntentStore.RecordRegistrationRedTest do
  @moduledoc """
  B1a-1 RED: the pane-intent record carries the pane's registration (NS-15.G.002, B1 design r5).

  Schema 2.0 adds `registration_id`: `reg_` plus 32 lowercase hex, or JSON null for a pane with no
  registration (a record first written by schema 1.0, or a pane re-admitted without one). The reader
  accepts exactly a pure 1.0 envelope or a pure 2.0 envelope; the writer always writes 2.0, re-encoding
  a 1.0 record with a null id. Admission keeps its own copy of the schema, and the two copies must agree.
  """

  use ExUnit.Case, async: true

  alias AiPair.PaneIntentStore.Record
  alias AiPair.PaneRestore.Admission

  @root "/state/root"
  @keys_1_0 ~w(
    schema_version pane_id agent classifier project project_dir project_inbox
    tmux_session session_gen cwd command pane_pid updated_at
  )
  @reg "reg_" <> String.duplicate("0123456789abcdef", 2)

  defp v1(overrides \\ %{}) do
    Map.merge(
      %{
        "schema_version" => "1.0",
        "pane_id" => pane(7),
        "agent" => "claude_code",
        "classifier" => "fingerprint:claude_code",
        "project" => "demo",
        "project_dir" => "/workspace/demo",
        "project_inbox" => @root,
        "tmux_session" => "ai-pair/demo",
        "session_gen" => "2",
        "cwd" => "/workspace/demo",
        "command" => "claude",
        "pane_pid" => 4242,
        "updated_at" => "2026-10-06T00:00:00Z"
      },
      overrides
    )
  end

  # Built at run time: bin/redaction-check refuses a literal tmux pane id in the tree.
  defp pane(n), do: "%" <> Integer.to_string(n)

  defp v2(overrides \\ %{}),
    do: Map.merge(v1(%{"schema_version" => "2.0", "registration_id" => @reg}), overrides)

  defp envelope(version, records),
    do:
      Jason.encode!(%{
        "schema_version" => version,
        "updated_at" => "2026-10-06T00:00:00Z",
        "attachments" => Map.new(records, &{&1["pane_id"], &1})
      })

  test "the writer version is 2.0 and the record has fourteen keys, the thirteen of 1.0 plus registration_id" do
    assert Record.version() == "2.0"
    assert Enum.sort(Record.record_keys()) == Enum.sort(["registration_id" | @keys_1_0])
  end

  test "a 2.0 record with a registration id, or with null, validates" do
    assert Record.validate(v2(), @root) == :ok
    assert Record.validate(v2(%{"registration_id" => nil}), @root) == :ok
  end

  test "a 1.0 record of exactly thirteen keys still validates" do
    assert Record.validate(v1(), @root) == :ok
  end

  test "a malformed registration id is refused" do
    for bad <- [
          "reg_" <> String.duplicate("A", 32),
          "reg_" <> String.duplicate("a", 31),
          "reg_" <> String.duplicate("a", 33),
          String.duplicate("a", 36),
          "",
          42
        ] do
      assert {:error, _} = Record.validate(v2(%{"registration_id" => bad}), @root)
    end
  end

  test "a version and key set that do not belong together is refused" do
    assert {:error, _} = Record.validate(Map.delete(v2(), "registration_id"), @root)
    assert {:error, _} = Record.validate(v1(%{"registration_id" => @reg}), @root)
    assert {:error, _} = Record.validate(v2(%{"schema_version" => "3.0"}), @root)
  end

  test "a pure 1.0 or a pure 2.0 envelope decodes; a mixed envelope is refused" do
    assert {:ok, [_]} = Record.decode_envelope(envelope("1.0", [v1()]), @root)
    assert {:ok, [_]} = Record.decode_envelope(envelope("2.0", [v2()]), @root)
    assert {:error, {:schema, _}} = Record.decode_envelope(envelope("2.0", [v1()]), @root)
    assert {:error, {:schema, _}} = Record.decode_envelope(envelope("1.0", [v2()]), @root)

    assert {:error, {:schema, _}} =
             Record.decode_envelope(envelope("2.0", [v2(), v1(%{"pane_id" => pane(8)})]), @root)
  end

  test "the writer re-encodes a 1.0 record as 2.0 with a null registration id" do
    bytes = Record.encode_envelope([v1()], ~U[2026-10-06 00:00:00Z])
    assert {:ok, [record]} = Record.decode_envelope(bytes, @root)
    assert record["schema_version"] == "2.0"
    assert Map.fetch(record, "registration_id") == {:ok, nil}
    assert record |> Map.delete("registration_id") |> Map.put("schema_version", "1.0") == v1()
  end

  test "admission's schema copy equals the record module's, version by version" do
    # apply/3: both functions are GREEN's, absent at the RED base.
    assert apply(Admission, :intent_schemas, []) == apply(Record, :schemas, [])

    assert apply(Record, :schemas, []) == %{
             "1.0" => Enum.sort(@keys_1_0),
             "2.0" => Enum.sort(["registration_id" | @keys_1_0])
           }
  end
end
