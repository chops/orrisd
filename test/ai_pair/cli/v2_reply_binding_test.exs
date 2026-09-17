defmodule AiPair.CLI.V2ReplyBindingTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  alias AiPair.CLI.Client

  @id "snd_" <> String.duplicate("a", 64)
  @pane "%reply_binding"
  @hash "sha256:" <> String.duplicate("b", 64)
  @diagnostic "ai-pair: protocol_error: daemon reply does not match the requested protocol or identity\n"

  setup do
    root = Path.join(System.tmp_dir!(), "reply_binding_#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    socket = Path.join(root, "reply.sock")
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

  for verb <- ~w(ping send reconcile) do
    for version <- [:missing, nil, 1, 2.0, "2", true] do
      test "#{verb} rejects reply version #{inspect(version)}", context do
        verb = unquote(verb)
        reply = replace(reply(verb), "protocol_version", unquote(version))
        assert_refused(invoke(context, verb, reply))
      end
    end

    for ok <- [:missing, nil, "true", 1] do
      test "#{verb} rejects nonboolean ok #{inspect(ok)}", context do
        verb = unquote(verb)
        reply = replace(reply(verb), "ok", unquote(ok))
        assert_refused(invoke(context, verb, reply))
      end
    end

    test "#{verb} preserves a valid bound success", context do
      verb = unquote(verb)
      reply = reply(verb)
      assert %{exit: 0, stdout: stdout, stderr: ""} = invoke(context, verb, reply)
      assert Jason.decode!(stdout) == reply
    end

    test "#{verb} preserves a valid bound daemon error", context do
      verb = unquote(verb)
      reply = Map.merge(reply(verb), %{"ok" => false, "error" => "receipt_store_unavailable"})
      assert %{exit: 1, stdout: stdout, stderr: ""} = invoke(context, verb, reply)
      assert Jason.decode!(stdout) == reply
    end
  end

  for verb <- ~w(send reconcile), ok <- [true, false] do
    for {key, value} <- [
          {"msg_id", :missing},
          {"msg_id", "snd_" <> String.duplicate("c", 64)},
          {"pane_id", :missing},
          {"pane_id", "%different"}
        ] do
      test "#{verb} ok=#{ok} rejects #{key}=#{inspect(value)}", context do
        verb = unquote(verb)

        reply =
          reply(verb)
          |> Map.put("ok", unquote(ok))
          |> Map.put("private_detail", "must never appear in diagnostics")
          |> replace(unquote(key), unquote(value))

        assert_refused(invoke(context, verb, reply))
      end
    end
  end

  for value <- [nil, [], "private reply bytes", true, 2] do
    test "send rejects a nonobject reply #{inspect(value)}", context do
      assert_refused(invoke(context, "send", unquote(Macro.escape(value))))
    end
  end

  test "versioned ping does not add a closed capability or response schema", context do
    reply = %{
      "ok" => true,
      "protocol_version" => 2,
      "capabilities" => ["delivery_reconcile", "future_capability"],
      "future_field" => "additive"
    }

    assert %{exit: 0, stdout: stdout, stderr: ""} = invoke(context, "ping", reply)
    assert Jason.decode!(stdout) == reply
  end

  for key <- ~w(msg_id pane_id) do
    test "reconcile refuses absent bound to a different #{key}", context do
      reply =
        reply("reconcile")
        |> Map.put("outcome", "absent")
        |> Map.put(unquote(key), "different-request")

      assert_refused(invoke(context, "reconcile", reply))
    end
  end

  for status <- ~w(delivered queued pending ambiguous) do
    test "send preserves a bound #{status} duplicate without interpreting its outcome", context do
      reply =
        Map.merge(reply("send"), %{
          "status" => unquote(status),
          "duplicate" => true,
          "delivery_attempt" => 3,
          "payload_hash" => @hash
        })

      assert %{exit: 0, stdout: stdout, stderr: ""} = invoke(context, "send", reply)
      assert Jason.decode!(stdout) == reply
    end
  end

  test "transport closure is an error without an absent reply", context do
    result = invoke(context, "reconcile", :close)
    assert result.exit == 1
    assert result.stdout == ""
    assert result.stderr == "ai-pair: :closed\n"
  end

  test "a bound unknown-command error stays an error without an absent outcome", context do
    reply =
      reply("reconcile")
      |> Map.delete("outcome")
      |> Map.merge(%{"ok" => false, "error" => "unknown command"})

    assert %{exit: 1, stdout: stdout, stderr: ""} = invoke(context, "reconcile", reply)
    assert Jason.decode!(stdout) == reply
    refute Map.has_key?(Jason.decode!(stdout), "outcome")
  end

  test "an unversioned unknown-command reply is a protocol error, not absence", context do
    assert_refused(invoke(context, "reconcile", %{"ok" => false, "error" => "unknown command"}))
  end

  for ok <- [true, false] do
    test "legacy send keeps unversioned ok=#{ok} output and exit behavior", context do
      reply = %{"ok" => unquote(ok), "status" => "sent"}
      args = ["send", @pane, "input", "--msg-id", "legacy-id"]
      expected = %{"cmd" => "send", "pane_id" => @pane, "text" => "input", "msg_id" => "legacy-id"}
      result = exchange(context.socket, reply, fn -> Client.main(args) end, expected)
      assert result.exit == if(unquote(ok), do: 0, else: 1)
      assert result.stderr == ""
      assert Jason.decode!(result.stdout) == reply
    end
  end

  test "raw request preserves its transport-only reply contract", context do
    request = %{"cmd" => "ping", "protocol_version" => 2}
    reply = %{"ok" => true}
    result = exchange(context.socket, reply, fn -> Client.request(request) end, request)
    assert result == %{exit: {:ok, reply}, stdout: "", stderr: ""}
  end

  defp invoke(context, verb, reply) do
    {args, request} = request(verb)
    exchange(context.socket, reply, fn -> Client.main(args) end, request)
  end

  defp request("ping"),
    do: {["ping", "--protocol-version", "2"], %{"cmd" => "ping", "protocol_version" => 2}}

  defp request("send") do
    {
      ["send", @pane, "input", "--msg-id", @id, "--protocol-version", "2"],
      %{
        "cmd" => "send",
        "protocol_version" => 2,
        "msg_id" => @id,
        "pane_id" => @pane,
        "text" => "input"
      }
    }
  end

  defp request("reconcile") do
    {
      ["reconcile", @pane, "--msg-id", @id, "--payload-hash", @hash, "--protocol-version", "2"],
      %{
        "cmd" => "reconcile",
        "protocol_version" => 2,
        "msg_id" => @id,
        "pane_id" => @pane,
        "payload_hash" => @hash,
        "wait_ms" => 250
      }
    }
  end

  defp reply("ping"),
    do: %{"ok" => true, "protocol_version" => 2, "capabilities" => ["delivery_reconcile"]}

  defp reply(verb) do
    %{"ok" => true, "protocol_version" => 2, "msg_id" => @id, "pane_id" => @pane}
    |> Map.put(if(verb == "send", do: "status", else: "outcome"), "delivered")
  end

  defp replace(reply, key, :missing), do: Map.delete(reply, key)
  defp replace(reply, key, value), do: Map.put(reply, key, value)

  defp assert_refused(result) do
    assert result == %{exit: 1, stdout: "", stderr: @diagnostic}
  end

  defp exchange(socket, reply, operation, expected_request) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ifaddr: {:local, socket}, active: false, packet: 4])

    server =
      Task.async(fn ->
        {:ok, connection} = :gen_tcp.accept(listener, 1_000)

        request =
          try do
            {:ok, frame} = :gen_tcp.recv(connection, 0, 1_000)

            unless reply == :close do
              :ok = :gen_tcp.send(connection, Jason.encode!(reply))
            end

            Jason.decode!(frame)
          after
            :gen_tcp.close(connection)
          end

        second_request =
          case :gen_tcp.accept(listener, 100) do
            {:error, :timeout} ->
              false

            {:ok, second} ->
              :gen_tcp.close(second)
              true
          end

        {request, second_request}
      end)

    try do
      ref = make_ref()

      stderr =
        capture_io(:stderr, fn ->
          stdout = capture_io(fn -> send(self(), {ref, :exit, operation.()}) end)
          send(self(), {ref, :stdout, stdout})
        end)

      assert_receive {^ref, :exit, exit}
      assert_receive {^ref, :stdout, stdout}
      {received, second_request} = Task.await(server, 2_000)
      assert Map.drop(received, ["traceparent", "tracestate"]) == expected_request
      refute second_request, "a rejected reply must never trigger an automatic retry"
      %{exit: exit, stdout: stdout, stderr: stderr}
    after
      :gen_tcp.close(listener)
      Task.shutdown(server, :brutal_kill)
    end
  end
end
