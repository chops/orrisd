defmodule AiPair.CLI.ClientTest do
  use ExUnit.Case, async: false

  alias AiPair.CLI.Client
  alias AiPair.Test.ReceiptBackedIPCServer, as: Server

  describe "argv/0" do
    test "returns [] when AI_PAIR_ARGV_B64 is unset" do
      System.delete_env("AI_PAIR_ARGV_B64")
      assert Client.argv() == []
    end

    test "returns [] when AI_PAIR_ARGV_B64 is empty" do
      System.put_env("AI_PAIR_ARGV_B64", "")
      on_exit(fn -> System.delete_env("AI_PAIR_ARGV_B64") end)
      assert Client.argv() == []
    end

    test "round-trips NUL-delimited argv with spaces and quotes" do
      argv = ["ping", "hello world", ~s(weird "quote"), "tab\there"]
      encoded = argv |> Enum.join(<<0>>) |> Base.encode64()
      System.put_env("AI_PAIR_ARGV_B64", encoded)
      on_exit(fn -> System.delete_env("AI_PAIR_ARGV_B64") end)

      assert Client.argv() == argv
    end

    test "preserves empty-string argv elements (no :trim_all)" do
      # printf '%s\0' "" foo "" bar produces \0foo\0\0bar\0
      raw = <<0>> <> "foo" <> <<0>> <> <<0>> <> "bar" <> <<0>>
      System.put_env("AI_PAIR_ARGV_B64", Base.encode64(raw))
      on_exit(fn -> System.delete_env("AI_PAIR_ARGV_B64") end)

      assert Client.argv() == ["", "foo", "", "bar"]
    end

    test "returns [] for invalid base64 instead of crashing" do
      System.put_env("AI_PAIR_ARGV_B64", "!!!not-base64!!!")
      on_exit(fn -> System.delete_env("AI_PAIR_ARGV_B64") end)
      assert Client.argv() == []
    end
  end

  describe "sock_path/0" do
    test "honors AI_PAIR_DAEMON_SOCK as an explicit full-path override" do
      System.put_env("AI_PAIR_DAEMON_SOCK", "/tmp/ai-pair-test-override/foo.sock")
      on_exit(fn -> System.delete_env("AI_PAIR_DAEMON_SOCK") end)
      assert Client.sock_path() == "/tmp/ai-pair-test-override/foo.sock"
    end

    test "falls back to $HOME/.ai-agent-inbox/ai-pair when no override is set" do
      System.delete_env("AI_PAIR_DAEMON_SOCK")
      expected = Path.join(System.user_home!(), ".ai-agent-inbox/ai-pair/sock/ai-pair.sock")
      assert Client.sock_path() == expected
    end

    test "ignores AI_PAIR_INBOX (project shells override that — daemon socket is global)" do
      System.delete_env("AI_PAIR_DAEMON_SOCK")
      System.put_env("AI_PAIR_INBOX", "/tmp/ai-pair-some-project-inbox")
      on_exit(fn -> System.delete_env("AI_PAIR_INBOX") end)
      expected = Path.join(System.user_home!(), ".ai-agent-inbox/ai-pair/sock/ai-pair.sock")
      assert Client.sock_path() == expected
    end

    test "empty AI_PAIR_DAEMON_SOCK falls back to default" do
      System.put_env("AI_PAIR_DAEMON_SOCK", "")
      on_exit(fn -> System.delete_env("AI_PAIR_DAEMON_SOCK") end)
      expected = Path.join(System.user_home!(), ".ai-agent-inbox/ai-pair/sock/ai-pair.sock")
      assert Client.sock_path() == expected
    end
  end

  describe "main/1" do
    test "help and -h print usage and return 0" do
      assert ExUnit.CaptureIO.capture_io(fn -> assert Client.main(["help"]) == 0 end) =~ "Usage:"
      assert ExUnit.CaptureIO.capture_io(fn -> assert Client.main(["-h"]) == 0 end) =~ "Usage:"

      assert ExUnit.CaptureIO.capture_io(fn -> assert Client.main(["--help"]) == 0 end) =~
               "Usage:"
    end

    test "unknown command prints to stderr and returns 2" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert Client.main(["bogus"]) == 2
        end)

      assert stderr =~ "unknown command"
    end

    test "ping with no daemon returns 1 with a useful error" do
      sock = "/tmp/ai-pair-no-daemon-#{System.unique_integer([:positive])}/sock/ai-pair.sock"
      System.put_env("AI_PAIR_DAEMON_SOCK", sock)
      on_exit(fn -> System.delete_env("AI_PAIR_DAEMON_SOCK") end)

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert Client.main(["ping"]) == 1
        end)

      assert stderr =~ "daemon socket not found"
    end

    test "attach without a pane_id prints usage and returns 2" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert Client.main(["attach"]) == 2
        end)

      assert stderr =~ "attach requires"
    end

    test "attach with extra args prints usage and returns 2" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert Client.main(["attach", "%1", "%2"]) == 2
        end)

      assert stderr =~ "attach requires"
    end

    test "attach with unknown flag prints usage and returns 2" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert Client.main(["attach", "%1", "--bogus", "x"]) == 2
        end)

      assert stderr =~ "attach requires"
    end
  end

  describe "parse_attach/1" do
    test "bare pane_id" do
      assert {:ok, "%1", nil} = Client.parse_attach(["%1"])
    end

    test "pane_id with --agent" do
      assert {:ok, "%1", "claude_code"} = Client.parse_attach(["%1", "--agent", "claude_code"])
    end

    test "--agent before pane_id" do
      assert {:ok, "%1", "codex_cli"} = Client.parse_attach(["--agent", "codex_cli", "%1"])
    end

    test "missing pane_id" do
      assert :error = Client.parse_attach([])
      assert :error = Client.parse_attach(["--agent", "claude_code"])
    end

    test "extra positional" do
      assert :error = Client.parse_attach(["%1", "%2"])
    end

    test "unknown flag" do
      assert :error = Client.parse_attach(["%1", "--bogus", "x"])
    end
  end

  describe "parse_send/1" do
    test "pane_id and literal text" do
      assert {:ok, "%1", {:literal, "hello"}, msg_id, true} =
               Client.parse_send(["%1", "hello"])

      assert msg_id =~ ~r/^m_\d+_[0-9a-f]{8}$/
    end

    test "pane_id with --stdin" do
      assert {:ok, "%1", :stdin, msg_id, true} = Client.parse_send(["%1", "--stdin"])
      assert msg_id =~ ~r/^m_\d+_[0-9a-f]{8}$/
    end

    test "--stdin before pane_id" do
      assert {:ok, "%1", :stdin, msg_id, true} = Client.parse_send(["--stdin", "%1"])
      assert msg_id =~ ~r/^m_\d+_[0-9a-f]{8}$/
    end

    test "missing pane_id" do
      assert :error = Client.parse_send([])
      assert :error = Client.parse_send(["--stdin"])
    end

    test "missing text and no --stdin" do
      assert :error = Client.parse_send(["%1"])
    end

    test "both literal text and --stdin is rejected" do
      assert :error = Client.parse_send(["%1", "hello", "--stdin"])
    end

    test "extra positional with --stdin is rejected" do
      assert :error = Client.parse_send(["%1", "hello", "extra", "--stdin"])
    end

    test "unknown flag" do
      assert :error = Client.parse_send(["%1", "--bogus", "x"])
    end

    test "--msg-id with literal text" do
      assert {:ok, "%1", {:literal, "hello"}, "01J9XABC", false} =
               Client.parse_send(["%1", "hello", "--msg-id", "01J9XABC"])
    end

    test "--msg-id with --stdin" do
      assert {:ok, "%1", :stdin, "01J9XABC", false} =
               Client.parse_send(["%1", "--stdin", "--msg-id", "01J9XABC"])
    end

    test "empty --msg-id is rejected" do
      assert :error = Client.parse_send(["%1", "hello", "--msg-id", ""])
    end
  end

  describe "parse_pane_status/1" do
    test "bare pane_id" do
      assert {:ok, "%1"} = Client.parse_pane_status(["%1"])
    end

    test "missing pane_id" do
      assert :error = Client.parse_pane_status([])
    end

    test "extra positional" do
      assert :error = Client.parse_pane_status(["%1", "%2"])
    end

    test "unknown flag" do
      assert :error = Client.parse_pane_status(["%1", "--bogus", "x"])
    end
  end

  describe "parse_detach/1" do
    test "bare pane_id" do
      assert {:ok, "%1"} = Client.parse_detach(["%1"])
    end

    test "missing pane_id" do
      assert :error = Client.parse_detach([])
    end

    test "extra positional" do
      assert :error = Client.parse_detach(["%1", "%2"])
    end

    test "unknown flag" do
      assert :error = Client.parse_detach(["%1", "--bogus", "x"])
    end
  end

  describe "pane_status main/1 without daemon" do
    test "pane_status without args prints usage and returns 2" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert Client.main(["pane_status"]) == 2
        end)

      assert stderr =~ "pane_status requires"
    end

    test "pane_status with extra positional prints usage and returns 2" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert Client.main(["pane_status", "%1", "%2"]) == 2
        end)

      assert stderr =~ "pane_status requires"
    end

    test "pane_status with unknown flag prints usage and returns 2" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert Client.main(["pane_status", "%1", "--bogus", "x"]) == 2
        end)

      assert stderr =~ "pane_status requires"
    end
  end

  describe "send main/1 without daemon" do
    test "send without enough args prints usage and returns 2" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert Client.main(["send"]) == 2
        end)

      assert stderr =~ "send requires"
    end

    test "send with bare pane_id (no text, no --stdin) prints usage and returns 2" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert Client.main(["send", "%1"]) == 2
        end)

      assert stderr =~ "send requires"
    end

    test "send with unknown flag prints usage and returns 2" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert Client.main(["send", "%1", "--bogus", "x"]) == 2
        end)

      assert stderr =~ "send requires"
    end
  end

  describe "detach main/1 without daemon" do
    test "detach without args prints usage and returns 2" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert Client.main(["detach"]) == 2
        end)

      assert stderr =~ "detach requires"
    end

    test "detach with extra positional prints usage and returns 2" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert Client.main(["detach", "%1", "%2"]) == 2
        end)

      assert stderr =~ "detach requires"
    end

    test "detach with unknown flag prints usage and returns 2" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert Client.main(["detach", "%1", "--bogus", "x"]) == 2
        end)

      assert stderr =~ "detach requires"
    end
  end

  describe "request/1 against a live IPC.Server" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "ai_pair_client_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, "sock"))
      File.chmod!(Path.join(tmp, "sock"), 0o700)
      System.put_env("AI_PAIR_INBOX", tmp)
      System.put_env("AI_PAIR_DAEMON_SOCK", Path.join(tmp, "sock/ai-pair.sock"))

      {:ok, pid} = Server.start_link(inbox: tmp, name: :client_test_server)

      on_exit(fn ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end
        end

        System.delete_env("AI_PAIR_INBOX")
        System.delete_env("AI_PAIR_DAEMON_SOCK")
        File.rm_rf!(tmp)
      end)

      :ok
    end

    test "ping round-trips through {:packet, 4} framing" do
      assert {:ok, %{"ok" => true, "pong" => v}} = Client.request(%{"cmd" => "ping"})
      assert is_binary(v)
    end

    test "unknown command returns {:ok, %{ok: false}} from the server" do
      assert {:ok, %{"ok" => false, "error" => "unknown command"}} =
               Client.request(%{"cmd" => "bogus"})
    end

    test "main(['ping']) prints a JSON reply and returns 0" do
      out = ExUnit.CaptureIO.capture_io(fn -> assert Client.main(["ping"]) == 0 end)
      assert {:ok, %{"ok" => true}} = Jason.decode(String.trim(out))
    end

    test "main([]) defaults to ping" do
      out = ExUnit.CaptureIO.capture_io(fn -> assert Client.main([]) == 0 end)
      assert {:ok, %{"ok" => true}} = Jason.decode(String.trim(out))
    end

    test "attach round-trips a successful payload through the daemon" do
      pane_id = "%cli-attach-#{System.unique_integer([:positive])}"
      on_exit(fn -> AiPair.PaneSupervisor.stop_pane(pane_id) end)

      assert {:ok, %{"ok" => true, "pane_id" => ^pane_id, "started" => true, "state" => state}} =
               Client.request(%{"cmd" => "attach_pane", "pane_id" => pane_id})

      assert state in ~w(idle busy dialog dead unknown)
    end

    test "main(['attach', pane_id]) prints a JSON reply and returns 0" do
      pane_id = "%cli-main-attach-#{System.unique_integer([:positive])}"
      on_exit(fn -> AiPair.PaneSupervisor.stop_pane(pane_id) end)

      out = ExUnit.CaptureIO.capture_io(fn -> assert Client.main(["attach", pane_id]) == 0 end)
      assert {:ok, %{"ok" => true, "started" => true}} = Jason.decode(String.trim(out))
    end

    test "main(['attach', pane_id, '--agent', 'claude_code']) wires the fingerprint classifier" do
      pane_id = "%cli-attach-fp-#{System.unique_integer([:positive])}"
      on_exit(fn -> AiPair.PaneSupervisor.stop_pane(pane_id) end)

      out =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Client.main(["attach", pane_id, "--agent", "claude_code"]) == 0
        end)

      assert {:ok,
              %{
                "ok" => true,
                "started" => true,
                "agent" => "claude_code",
                "classifier" => "fingerprint:claude_code"
              }} = Jason.decode(String.trim(out))
    end

    test "send to a missing pane returns ok:false / pane_not_found and exits 1" do
      pane_id = "%cli-send-missing-#{System.unique_integer([:positive])}"

      out =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Client.main(["send", pane_id, "hello"]) == 1
        end)

      assert {:ok, %{"ok" => false, "error" => "pane_not_found", "pane_id" => ^pane_id}} =
               Jason.decode(String.trim(out))
    end

    test "send via --stdin reads stdin and forwards as text" do
      pane_id = "%cli-send-stdin-#{System.unique_integer([:positive])}"

      out =
        ExUnit.CaptureIO.capture_io("multi\nline\ninput", fn ->
          assert Client.main(["send", pane_id, "--stdin"]) == 1
        end)

      # No pane attached → still hits the daemon, which returns pane_not_found.
      # This proves the CLI reached the IPC layer with a stdin-derived text body.
      assert {:ok, %{"ok" => false, "error" => "pane_not_found"}} = Jason.decode(String.trim(out))
    end

    test "send to an attached pane returns a status envelope and exits 0/1 accordingly" do
      pane_id = "%cli-send-attached-#{System.unique_integer([:positive])}"
      on_exit(fn -> AiPair.PaneSupervisor.stop_pane(pane_id) end)

      assert {:ok, %{"ok" => true}} =
               Client.request(%{"cmd" => "attach_pane", "pane_id" => pane_id})

      out =
        ExUnit.CaptureIO.capture_io(fn ->
          # Real tmux is not running for this synthetic pane, so the SM
          # rapidly transitions to :dead. Either an ok:true queued/sent
          # envelope or an ok:false pane_dead envelope is acceptable —
          # this test covers shape + exit-code mapping.
          rc = Client.main(["send", pane_id, "hello"])
          assert rc in [0, 1]
        end)

      decoded = Jason.decode!(String.trim(out))
      assert decoded["pane_id"] == pane_id

      case decoded do
        %{"ok" => true, "status" => status} -> assert status in ~w(sent queued)
        %{"ok" => false, "error" => err} -> assert err in ~w(pane_dead pane_not_found)
      end
    end

    test "pane_status against a missing pane returns ok:false / pane_not_found and exits 1" do
      pane_id = "%cli-pane-status-missing-#{System.unique_integer([:positive])}"

      out =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Client.main(["pane_status", pane_id]) == 1
        end)

      assert {:ok, %{"ok" => false, "error" => "pane_not_found", "pane_id" => ^pane_id}} =
               Jason.decode(String.trim(out))
    end

    test "pane_status against an attached pane returns the full envelope and exits 0" do
      pane_id = "%cli-pane-status-attached-#{System.unique_integer([:positive])}"
      on_exit(fn -> AiPair.PaneSupervisor.stop_pane(pane_id) end)

      assert {:ok, %{"ok" => true}} =
               Client.request(%{
                 "cmd" => "attach_pane",
                 "pane_id" => pane_id,
                 "agent" => "claude_code"
               })

      out =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Client.main(["pane_status", pane_id]) == 0
        end)

      assert {:ok,
              %{
                "ok" => true,
                "pane_id" => ^pane_id,
                "agent" => "claude_code",
                "classifier" => "fingerprint:claude_code",
                "pending_count" => 0,
                "state" => state
              }} = Jason.decode(String.trim(out))

      assert state in ~w(idle busy dialog dead unknown)
    end

    test "detach against a missing pane returns ok:false / pane_not_found and exits 1" do
      pane_id = "%cli-detach-missing-#{System.unique_integer([:positive])}"

      out =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Client.main(["detach", pane_id]) == 1
        end)

      assert {:ok, %{"ok" => false, "error" => "pane_not_found", "pane_id" => ^pane_id}} =
               Jason.decode(String.trim(out))
    end

    test "main(['detach', pane_id]) round-trips a successful payload through the daemon" do
      pane_id = "%cli-detach-ok-#{System.unique_integer([:positive])}"
      on_exit(fn -> AiPair.PaneSupervisor.stop_pane(pane_id) end)

      assert {:ok, %{"ok" => true}} =
               Client.request(%{"cmd" => "attach_pane", "pane_id" => pane_id})

      out =
        ExUnit.CaptureIO.capture_io(fn -> assert Client.main(["detach", pane_id]) == 0 end)

      assert {:ok, %{"ok" => true, "pane_id" => ^pane_id, "status" => status}} =
               Jason.decode(String.trim(out))

      assert status in ~w(detached already_detached)
    end
  end
end
