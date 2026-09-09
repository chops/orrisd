defmodule AiPair.CLI.ConsultTest do
  use ExUnit.Case, async: false

  import AiPair.Test.OtelHelper

  alias AiPair.CLI.Client
  alias AiPair.CLI.Consult

  @self_pane "%consult-self"
  @peer_pane "%consult-peer"

  describe "argv parsing" do
    test "literal text mints a msg_id and joins body args" do
      assert {:ok, opts} = Client.parse_consult(["please", "review"])

      assert opts.source == {:literal, "please review"}
      assert opts.peer == nil
      assert opts.wait? == false
      assert opts.wait_secs == nil
      assert opts.msg_id_minted? == true
      assert opts.msg_id =~ ~r/^m_\d+_[0-9a-f]{8}$/
    end

    test "--stdin with --peer, --wait seconds, and --msg-id override" do
      assert {:ok, opts} =
               Client.parse_consult([
                 "--stdin",
                 "--peer",
                 "claude_code",
                 "--wait",
                 "30",
                 "--msg-id",
                 "consult_msg_0001"
               ])

      assert opts.source == :stdin
      assert opts.peer == "claude_code"
      assert opts.wait? == true
      assert opts.wait_secs == 30
      assert opts.msg_id == "consult_msg_0001"
      assert opts.msg_id_minted? == false
    end

    test "--wait without seconds uses the 600s default and keeps following text as body" do
      assert {:ok, opts} = Client.parse_consult(["--wait", "please", "answer"])

      assert opts.wait? == true
      assert opts.wait_secs == 600
      assert opts.source == {:literal, "please answer"}
    end

    test "invalid combinations are rejected" do
      assert :error = Client.parse_consult([])
      assert :error = Client.parse_consult(["--stdin", "body"])
      assert :error = Client.parse_consult(["body", "--peer", "not_a_peer"])
      assert :error = Client.parse_consult(["body", "--msg-id", "short"])
      assert :error = Client.parse_consult(["body", "--wait", "-1"])
      assert :error = Client.parse_consult(["body", "--bogus"])
    end
  end

  describe "msg_id helpers" do
    test "minted ids match the send-style shape" do
      assert Consult.mint_msg_id() =~ ~r/^m_\d+_[0-9a-f]{8}$/
    end

    test "override validation follows the schema bounds" do
      assert Consult.valid_msg_id?("consult_msg_0001")
      refute Consult.valid_msg_id?("short")
      refute Consult.valid_msg_id?(String.duplicate("a", 65))
      refute Consult.valid_msg_id?("not valid whitespace")
    end
  end

  describe "envelope publish" do
    setup :tmp_inbox

    test "writes the consultation envelope and wakes the peer", %{inbox: inbox} do
      id = "consult_msg_1001"
      {:ok, opts} = Client.parse_consult(["--msg-id", id, "check", "this"])
      request_fn = request_fn(self())

      out =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Consult.run(opts, runtime(inbox, request_fn)) == 0
        end)

      assert %{"ok" => true, "msg_id" => ^id, "kind" => "consultation"} =
               Jason.decode!(String.trim(out))

      assert_received {:send_request,
                       %{
                         "cmd" => "send",
                         "pane_id" => @peer_pane,
                         "msg_id" => ^id,
                         "text" => nudge
                       }}

      assert nudge =~ id

      refute File.exists?(Path.join([inbox, "outbox", "#{id}.json"]))

      envelope =
        inbox
        |> Path.join("inbox/#{id}.json")
        |> File.read!()
        |> Jason.decode!()

      assert %{
               "schema_version" => "1.0",
               "msg_id" => ^id,
               "from" => %{"agent" => "codex", "pane_id" => @self_pane},
               "to" => %{"agent" => "claude", "pane_id" => @peer_pane},
               "kind" => "consultation",
               "body" => "check this",
               "context" => %{"project" => "ai-pair"}
             } = envelope

      assert envelope["ts"] =~ ~r/^\d{4}-\d{2}-\d{2}T.*Z$/
    end

    test "--stdin body is written into the envelope", %{inbox: inbox} do
      id = "consult_msg_1002"
      {:ok, opts} = Client.parse_consult(["--stdin", "--msg-id", id])
      request_fn = request_fn(self())

      ExUnit.CaptureIO.capture_io(fn ->
        assert Consult.run(
                 opts,
                 runtime(inbox, request_fn, stdin_fn: fn -> "from\nstdin\n" end)
               ) == 0
      end)

      envelope =
        inbox
        |> Path.join("inbox/#{id}.json")
        |> File.read!()
        |> Jason.decode!()

      assert envelope["body"] == "from\nstdin\n"
    end
  end

  describe "--wait" do
    setup :tmp_inbox

    test "prints the correlated reply body", %{inbox: inbox} do
      id = "consult_wait_1001"
      {:ok, opts} = Client.parse_consult(["--wait", "1", "--msg-id", id, "need", "answer"])
      write_reply!(inbox, id, "reply body")

      out =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Consult.run(opts, runtime(inbox, request_fn(self()))) == 0
        end)

      assert out == "reply body\n"
    end

    test "returns 1 on timeout", %{inbox: inbox} do
      id = "consult_wait_1002"
      {:ok, opts} = Client.parse_consult(["--wait", "0", "--msg-id", id, "need", "answer"])

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert Consult.run(
                   opts,
                   runtime(inbox, request_fn(self()), sleep_fn: fn _ -> flunk("slept") end)
                 ) ==
                   1
        end)

      assert stderr =~ "timed out waiting 0s for reply to #{id}"
    end
  end

  describe "otel surface" do
    setup :tmp_inbox
    setup :setup_otel_capture

    test "sets cli.consult span attributes without asserting e2e propagation", %{inbox: inbox} do
      id = "consult_otel_1001"

      {:ok, opts} =
        Client.parse_consult(["--peer", "claude_code", "--msg-id", id, "trace", "attrs"])

      ExUnit.CaptureIO.capture_io(fn ->
        assert Consult.run(opts, runtime(inbox, request_fn(self()))) == 0
      end)

      assert {:ok, span} = assert_span(name: "cli.consult", kind: :client)
      attrs = span_attrs(span)

      assert attrs["messaging.message.id"] == id
      assert attrs["peer.agent"] == "claude_code"
      assert attrs["peer.pane_id"] == @peer_pane
    end
  end

  defp tmp_inbox(_context) do
    inbox = Path.join(System.tmp_dir!(), "ai_pair_consult_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(inbox, "inbox"))
    File.mkdir_p!(Path.join(inbox, "outbox"))

    on_exit(fn -> File.rm_rf!(inbox) end)

    %{inbox: inbox}
  end

  defp runtime(inbox, request_fn, overrides \\ []) do
    Keyword.merge(
      [
        request_fn: request_fn,
        tmux_panes_fn: fn -> {:ok, [@self_pane, @peer_pane]} end,
        env: %{
          "AI_PAIR_INBOX" => inbox,
          "AI_PAIR_PROJECT" => "ai-pair",
          "TMUX_PANE" => @self_pane
        }
      ],
      overrides
    )
  end

  defp request_fn(parent) do
    fn
      %{"cmd" => "pane_status", "pane_id" => @self_pane} ->
        {:ok,
         %{
           "ok" => true,
           "pane_id" => @self_pane,
           "agent" => "codex_cli",
           "classifier" => "fingerprint:codex_cli"
         }}

      %{"cmd" => "pane_status", "pane_id" => @peer_pane} ->
        {:ok,
         %{
           "ok" => true,
           "pane_id" => @peer_pane,
           "agent" => "claude_code",
           "classifier" => "fingerprint:claude_code"
         }}

      %{"cmd" => "send"} = payload ->
        send(parent, {:send_request, payload})
        {:ok, %{"ok" => true, "status" => "queued"}}
    end
  end

  defp write_reply!(inbox, in_reply_to, body) do
    reply = %{
      "schema_version" => "1.0",
      "msg_id" => "reply_#{in_reply_to}",
      "ts" => "2026-05-22T00:00:00Z",
      "from" => %{"agent" => "claude", "pane_id" => @peer_pane},
      "to" => %{"agent" => "codex", "pane_id" => @self_pane},
      "kind" => "answer",
      "in_reply_to" => in_reply_to,
      "body" => body
    }

    File.write!(Path.join([inbox, "inbox", "reply-#{in_reply_to}.json"]), Jason.encode!(reply))
  end
end
