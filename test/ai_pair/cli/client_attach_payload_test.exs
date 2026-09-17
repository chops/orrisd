defmodule AiPair.CLI.ClientAttachPayloadTest do
  # R04 slice S3: the pure attach payload builder. This is the T1 row of the
  # reviewed boot-wiring RED (56b5c7b:test/ai_pair/pane_restore/boot_wiring_test.exs
  # :4092-4121), lifted out of that file so it needs no RouteGuard, no tmux and
  # no daemon: `Client.attach_payload/3` is a pure function of its arguments.
  #
  # Pane ids are built at runtime from the `%<digits>` form the daemon expects,
  # so the source contains no literal pane id for the redaction scanner.
  use ExUnit.Case, async: true

  alias AiPair.CLI.Client

  defp synthetic_pane_id, do: "%" <> Integer.to_string(System.unique_integer([:positive]))

  describe "attach_payload/3 returns exactly the business keys (T1)" do
    test "no agent, not durable: cmd and pane_id only" do
      pane_id = synthetic_pane_id()

      assert Client.attach_payload(pane_id, nil, false) == %{
               "cmd" => "attach_pane",
               "pane_id" => pane_id
             }
    end

    test "agent given, not durable: adds agent and nothing else" do
      pane_id = synthetic_pane_id()

      assert Client.attach_payload(pane_id, "claude_code", false) == %{
               "cmd" => "attach_pane",
               "pane_id" => pane_id,
               "agent" => "claude_code"
             }
    end

    test "agent given and durable: adds both" do
      pane_id = synthetic_pane_id()

      assert Client.attach_payload(pane_id, "claude_code", true) == %{
               "cmd" => "attach_pane",
               "pane_id" => pane_id,
               "agent" => "claude_code",
               "durable" => true
             }
    end

    # durable without an agent: `durable` present, NO `agent` key at all. A
    # builder that emits "agent" => nil only in this case passes the three
    # cases above and fails here.
    test "durable without an agent: durable present, no agent key" do
      pane_id = synthetic_pane_id()

      assert Client.attach_payload(pane_id, nil, true) == %{
               "cmd" => "attach_pane",
               "pane_id" => pane_id,
               "durable" => true
             }
    end
  end

  describe "the legacy frame bytes are unchanged" do
    # Before this slice `attach/2` built the frame map inline. These are the
    # encoded bytes that inline map produced for the two existing CLI cases
    # (`attach <pane_id>` and `attach <pane_id> --agent <name>`), frozen here as
    # literals so a later change to the builder that reorders, renames or adds
    # a key on the non-durable path fails against fixed bytes, not against a
    # value derived from the code under test.
    test "attach without --agent encodes to the same bytes as the previous inline map" do
      pane_id = synthetic_pane_id()
      expected = ~s({"cmd":"attach_pane","pane_id":"#{pane_id}"})

      assert Jason.encode!(Client.attach_payload(pane_id, nil, false)) == expected
      assert Jason.encode!(%{"cmd" => "attach_pane", "pane_id" => pane_id}) == expected
    end

    test "attach with --agent encodes to the same bytes as the previous inline map" do
      pane_id = synthetic_pane_id()
      expected = ~s({"agent":"codex_cli","cmd":"attach_pane","pane_id":"#{pane_id}"})

      assert Jason.encode!(Client.attach_payload(pane_id, "codex_cli", false)) == expected

      assert Jason.encode!(%{"cmd" => "attach_pane", "pane_id" => pane_id, "agent" => "codex_cli"}) ==
               expected
    end

    test "the non-durable payload never carries a durable key, true or false" do
      pane_id = synthetic_pane_id()

      refute Map.has_key?(Client.attach_payload(pane_id, nil, false), "durable")
      refute Map.has_key?(Client.attach_payload(pane_id, "claude_code", false), "durable")
    end
  end
end
