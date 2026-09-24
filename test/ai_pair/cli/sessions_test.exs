defmodule AiPair.CLI.SessionsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  alias AiPair.CLI.Client

  @ping %{"cmd" => "ping", "protocol_version" => 2}
  @sessions %{"cmd" => "sessions", "protocol_version" => 2}
  @preflight_error "ai-pair: sessions unavailable: capability preflight failed\n"
  @reply_error "ai-pair: protocol_error: invalid sessions reply\n"
  @transport_error "ai-pair: sessions unavailable: daemon request failed\n"

  setup do
    root = Path.join(System.tmp_dir!(), "sessions_cli_#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    socket = Path.join(root, "sessions.sock")
    previous = System.get_env("AI_PAIR_DAEMON_SOCK")
    System.put_env("AI_PAIR_DAEMON_SOCK", socket)

    on_exit(fn ->
      if previous,
        do: System.put_env("AI_PAIR_DAEMON_SOCK", previous),
        else: System.delete_env("AI_PAIR_DAEMON_SOCK")

      File.rm_rf!(root)
    end)

    %{socket: socket}
  end

  for args <- [["sessions"], ["sessions", "--protocol-version", "2"]] do
    test "#{inspect(args)} sends a private ping followed by exactly one sessions request",
         context do
      reply = success()
      result = exchange(context.socket, unquote(args), [ping(), reply], [@ping, @sessions])
      assert result.exit == 0
      assert result.stderr == ""
      assert result.stdout == Jason.encode!(reply) <> "\n"
    end
  end

  test "empty census success prints only the validated sessions reply", context do
    reply = %{"protocol_version" => 2, "ok" => true, "sessions" => []}
    result = exchange(context.socket, ["sessions"], [ping(), reply], [@ping, @sessions])
    assert result == %{exit: 0, stdout: Jason.encode!(reply) <> "\n", stderr: ""}
  end

  test "preflight permits additional opaque capabilities and ping fields without printing them",
       context do
    preflight =
      ping()
      |> Map.put("capabilities", ["future_capability", "sessions_read"])
      |> Map.put("private_ping_detail", "never print this")

    reply = success()
    result = exchange(context.socket, ["sessions"], [preflight, reply], [@ping, @sessions])
    assert result == %{exit: 0, stdout: Jason.encode!(reply) <> "\n", stderr: ""}
  end

  for args <- [
        ["--protocol-version", "1"],
        ["--protocol-version", "3"],
        ["--protocol-version", "2.0"],
        ["--protocol-version"],
        ["--protocol-version", "2", "--protocol-version", "2"],
        ["--project", "private-project"],
        ["--stdin"],
        ["--unknown"],
        ["positional"],
        ["--protocol-version", "2", "positional"]
      ] do
    test "invalid sessions arguments #{inspect(args)} perform zero socket requests", context do
      result = exchange(context.socket, ["sessions" | unquote(args)], [], [])
      assert result.exit == 2
      assert result.stdout == ""
      assert result.stderr =~ "sessions accepts only --protocol-version 2"
    end
  end

  for {key, value} <- [
        {"protocol_version", :missing},
        {"protocol_version", 1},
        {"protocol_version", 2.0},
        {"protocol_version", "2"},
        {"ok", :missing},
        {"ok", false},
        {"ok", "true"},
        {"capabilities", :missing},
        {"capabilities", []},
        {"capabilities", ["delivery_reconcile"]},
        {"capabilities", "sessions_read"},
        {"capabilities", ["sessions_read", 1]}
      ] do
    test "preflight refuses #{key}=#{inspect(value)} without a sessions request", context do
      reply = replace(ping(), unquote(key), unquote(Macro.escape(value)))
      result = exchange(context.socket, ["sessions"], [reply], [@ping])
      assert result == %{exit: 1, stdout: "", stderr: @preflight_error}
    end
  end

  for reply <- [nil, [], "private ping payload", :close, {:raw, "invalid private JSON"}] do
    test "preflight refuses #{inspect(reply)} without fallback or retry", context do
      result = exchange(context.socket, ["sessions"], [unquote(Macro.escape(reply))], [@ping])
      assert result == %{exit: 1, stdout: "", stderr: @preflight_error}
    end
  end

  test "an absent private daemon socket fails without printing the path", context do
    assert Client.sock_path() == context.socket

    assert capture(fn -> Client.main(["sessions"]) end) ==
             %{exit: 1, stdout: "", stderr: @preflight_error}
  end

  for error <- ~w(sessions_unavailable invalid_sessions_census invalid_sessions_request oversize) do
    test "typed sessions error #{error} prints validated JSON and exits one", context do
      reply = %{"protocol_version" => 2, "ok" => false, "error" => unquote(error)}
      result = exchange(context.socket, ["sessions"], [ping(), reply], [@ping, @sessions])
      assert result == %{exit: 1, stdout: Jason.encode!(reply) <> "\n", stderr: ""}
    end
  end

  for reply <- [
        nil,
        [],
        "private sessions payload",
        %{"ok" => true, "sessions" => []},
        %{"protocol_version" => 1, "ok" => true, "sessions" => []},
        %{"protocol_version" => 2.0, "ok" => true, "sessions" => []},
        %{"protocol_version" => 2, "ok" => "true", "sessions" => []},
        %{"protocol_version" => 2, "ok" => true, "sessions" => "private data"},
        %{"protocol_version" => 2, "ok" => true, "sessions" => [], "path" => "private path"},
        %{"protocol_version" => 2, "ok" => false, "error" => "unknown command"},
        %{
          "protocol_version" => 2,
          "ok" => false,
          "error" => "sessions_unavailable",
          "detail" => "private"
        }
      ] do
    test "malformed sessions reply #{inspect(reply)} produces no stdout or retry", context do
      result =
        exchange(context.socket, ["sessions"], [ping(), unquote(Macro.escape(reply))], [
          @ping,
          @sessions
        ])

      assert result == %{exit: 1, stdout: "", stderr: @reply_error}
    end
  end

  test "nested unselected fields are refused before printing", context do
    reply =
      update_in(
        success(),
        ["sessions", Access.at(0), "panes", Access.at(0)],
        &Map.put(&1, "pid", 99)
      )

    result = exchange(context.socket, ["sessions"], [ping(), reply], [@ping, @sessions])
    assert result == %{exit: 1, stdout: "", stderr: @reply_error}
  end

  test "repeated session identities are refused before printing", context do
    reply = update_in(success(), ["sessions"], fn sessions -> sessions ++ sessions end)
    result = exchange(context.socket, ["sessions"], [ping(), reply], [@ping, @sessions])
    assert result == %{exit: 1, stdout: "", stderr: @reply_error}
  end

  for reply <- [:close, {:raw, "private invalid sessions JSON"}] do
    test "sessions transport failure #{inspect(reply)} never retries or leaks bytes", context do
      result =
        exchange(context.socket, ["sessions"], [ping(), unquote(Macro.escape(reply))], [
          @ping,
          @sessions
        ])

      assert result == %{exit: 1, stdout: "", stderr: @transport_error}
    end
  end

  defp ping do
    %{
      "protocol_version" => 2,
      "ok" => true,
      "pong" => "private preflight version",
      "capabilities" => ["delivery_reconcile", "sessions_read"]
    }
  end

  defp success do
    %{
      "protocol_version" => 2,
      "ok" => true,
      "sessions" => [
        %{
          "session_id" => "$1",
          "session_name" => "sessions test",
          "panes" => [
            %{
              "pane_id" => "%" <> Integer.to_string(1),
              "window_index" => 0,
              "pane_index" => 0,
              "registered_at_observation" => false
            }
          ]
        }
      ]
    }
  end

  defp replace(reply, key, :missing), do: Map.delete(reply, key)
  defp replace(reply, key, value), do: Map.put(reply, key, value)

  defp exchange(socket, args, replies, expected_requests) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ifaddr: {:local, socket}, active: false, packet: 4])

    server =
      Task.async(fn ->
        received = Enum.map(replies, &serve_reply(listener, &1))

        extra_connection =
          case :gen_tcp.accept(listener, 100) do
            {:error, :timeout} ->
              false

            {:ok, extra} ->
              :gen_tcp.close(extra)
              true
          end

        {received, extra_connection}
      end)

    try do
      result = capture(fn -> Client.main(args) end)
      {received, extra_connection} = Task.await(server, 3_000)
      assert Enum.map(received, &Map.drop(&1, ["traceparent", "tracestate"])) == expected_requests

      refute extra_connection,
             "the CLI opened an extra connection (retry, fallback or invalid-argument I/O)"

      result
    after
      :gen_tcp.close(listener)
      Task.shutdown(server, :brutal_kill)
    end
  end

  defp serve_reply(listener, reply) do
    {:ok, connection} = :gen_tcp.accept(listener, 1_000)

    try do
      {:ok, frame} = :gen_tcp.recv(connection, 0, 1_000)

      case reply do
        :close -> :ok
        {:raw, bytes} -> :ok = :gen_tcp.send(connection, bytes)
        value -> :ok = :gen_tcp.send(connection, Jason.encode!(value))
      end

      Jason.decode!(frame)
    after
      :gen_tcp.close(connection)
    end
  end

  defp capture(operation) do
    ref = make_ref()

    stderr =
      capture_io(:stderr, fn ->
        stdout = capture_io(fn -> send(self(), {ref, :exit, operation.()}) end)
        send(self(), {ref, :stdout, stdout})
      end)

    assert_receive {^ref, :exit, exit}
    assert_receive {^ref, :stdout, stdout}
    %{exit: exit, stdout: stdout, stderr: stderr}
  end
end
