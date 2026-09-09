defmodule AiPair.CLI.VersionedDeliveryTest do
  use ExUnit.Case, async: true
  alias AiPair.CLI.Client
  @id "snd_" <> String.duplicate("a", 64)
  @hash "sha256:" <> String.duplicate("b", 64)

  defp parse(verb, args), do: apply(Client, :parse_versioned, [verb, args])

  test "ping states version two" do
    assert {:ok, %{"cmd" => "ping", "protocol_version" => 2}, :none} =
             parse("ping", ["--protocol-version", "2"])
  end

  test "send carries an explicit stable id and reads bytes only from its input source" do
    assert {:ok, payload, :stdin} =
             parse("send", ["%test", "--stdin", "--msg-id", @id, "--protocol-version", "2"])

    assert payload == %{
             "cmd" => "send",
             "pane_id" => "%test",
             "msg_id" => @id,
             "protocol_version" => 2
           }
  end

  test "reconcile carries a digest without prompt bytes" do
    args = [
      "%test",
      "--msg-id",
      @id,
      "--payload-hash",
      @hash,
      "--protocol-version",
      "2",
      "--wait-ms",
      "500"
    ]

    assert {:ok, payload, :none} = parse("reconcile", args)
    assert payload["payload_hash"] == @hash
    assert payload["wait_ms"] == 500
    refute Map.has_key?(payload, "text")
  end

  test "an unversioned send keeps the legacy route" do
    assert :legacy = parse("send", ["%test", "message"])
  end

  for {verb, args} <- [
        {"send", ["%test", "--stdin", "--protocol-version", "2"]},
        {"send", ["%test", "--stdin", "--msg-id", "m_legacy", "--protocol-version", "2"]},
        {"reconcile", ["%test", "--msg-id", @id, "--payload-hash", @hash]},
        {"reconcile", ["%test", "--msg-id", @id, "--protocol-version", "2"]},
        {"reconcile",
         ["%test", "--msg-id", @id, "--payload-hash", @hash <> "\n", "--protocol-version", "2"]},
        {"reconcile",
         [
           "%test",
           "--msg-id",
           @id,
           "--payload-hash",
           @hash,
           "--protocol-version",
           "2",
           "--wait-ms",
           "-1"
         ]},
        {"ping", ["--protocol-version", "99"]},
        {"ping", ["--protocol-version", "2", "--protocol-version", "2"]}
      ] do
    test "refuses #{verb} #{inspect(args)}" do
      assert :error = parse(unquote(verb), unquote(args))
    end
  end
end
