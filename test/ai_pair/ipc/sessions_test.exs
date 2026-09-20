defmodule AiPair.IPC.SessionsTest do
  use ExUnit.Case, async: true

  alias AiPair.IPC.Sessions

  @request %{"cmd" => "sessions", "protocol_version" => 2}
  @limit 1_048_576

  test "projection groups by id, orders numeric addresses, and omits raw fields" do
    rows = [
      row(1, "$2", 10, 0),
      row(2, "$10", 0, 10),
      row(3, "$2", 2, 0),
      row(4, "$10", 0, 2)
    ]

    reply = Sessions.project(rows, MapSet.new([pane(1), pane(4)]))
    assert reply["ok"]
    assert Sessions.valid_reply?(reply)
    assert Enum.map(reply["sessions"], & &1["session_id"]) == ["$10", "$2"]
    [first, second] = reply["sessions"]
    assert Enum.map(first["panes"], & &1["pane_index"]) == [2, 10]
    assert Enum.map(second["panes"], & &1["window_index"]) == [2, 10]
    assert Enum.map(first["panes"], & &1["registered_at_observation"]) == [true, false]
    assert Map.keys(reply) |> Enum.sort() == ~w(ok protocol_version sessions)
    refute Jason.encode!(reply) =~ "private-command"
    refute Jason.encode!(reply) =~ "private-path"
    assert Sessions.project(Enum.reverse(rows), MapSet.new([pane(4), pane(1)])) == reply
  end

  test "linked addresses share one registry membership, including false" do
    rows = [row(1, "$1", 0, 0), row(1, "$1", 2, 0), row(1, "$2", 0, 0)]

    for registered <- [MapSet.new(), MapSet.new([pane(1)])] do
      reply = Sessions.project(rows, registered)
      assert reply["ok"]
      addresses = Enum.flat_map(reply["sessions"], & &1["panes"])
      assert length(addresses) == 3

      assert Enum.map(addresses, & &1["registered_at_observation"]) ==
               List.duplicate(MapSet.member?(registered, pane(1)), 3)
    end
  end

  test "duplicate addresses and contradictory names refuse the whole census" do
    first = row(1, "$1", 0, 0)

    for rows <- [
          [first, first],
          [first, %{first | pane_id: pane(2)}],
          [first, %{row(2, "$1", 0, 1) | session_name: "different"}]
        ] do
      assert Sessions.project(rows, MapSet.new()) == failure("invalid_sessions_census")
    end
  end

  test "the same name is allowed for different session ids and retained verbatim" do
    name = "quote \" slash \\ pipe | tab\t newline\n " <> <<0xC3, 0xA9>>
    rows = for id <- ["$1", "$2"], do: %{row(1, id, 0, 0) | session_name: name}
    reply = Sessions.project(rows, MapSet.new())
    assert reply["ok"]
    assert Enum.map(reply["sessions"], & &1["session_name"]) == [name, name]
    assert reply |> Jason.encode!() |> Jason.decode!() == reply
  end

  test "malformed observations are neither coerced nor silently dropped" do
    good = row(1, "$1", 0, 0)

    bad = [
      Map.delete(good, :pane_index),
      Map.put(good, :extra, true),
      %{good | pane_id: "%synthetic"},
      %{good | session_id: "$synthetic"},
      %{good | pane_index: "1"},
      %{good | window_index: -1},
      %{good | session_name: ""},
      %{good | session_name: <<255>>},
      %{good | pane_pid: 0},
      %{good | command: ""},
      %{good | path: ""},
      nil
    ]

    for invalid <- bad do
      assert Sessions.project([good, invalid], MapSet.new()) == failure("invalid_sessions_census")
    end

    assert Sessions.project(:not_a_list, MapSet.new()) == failure("invalid_sessions_census")
  end

  test "empty successful census still reads registration once and answers empty" do
    opts = [
      observe: fn ->
        send(self(), :observed)
        {:ok, []}
      end,
      registered: fn ->
        send(self(), :registered)
        MapSet.new()
      end
    ]

    assert Sessions.dispatch(@request, opts) == %{
             "protocol_version" => 2,
             "ok" => true,
             "sessions" => []
           }

    assert_received :observed
    assert_received :registered
    refute_received :observed
    refute_received :registered
  end

  test "failed or malformed census never reads registration or succeeds empty" do
    cases = [
      {{:error, %{status: 1, stderr: "private-path"}}, "sessions_unavailable"},
      {{:error, {:row_arity, 8, 3, 1}}, "invalid_sessions_census"},
      {{:error, {:malformed_pid, "private-pid"}}, "invalid_sessions_census"},
      {{:error, {:malformed_index, :pane_index, "private-index"}}, "invalid_sessions_census"},
      {{:error, {:malformed_text, :path, "private-path"}}, "invalid_sessions_census"}
    ]

    for {result, error} <- cases do
      opts = [
        observe: fn -> result end,
        registered: fn ->
          send(self(), :registered)
          MapSet.new()
        end
      ]

      assert Sessions.dispatch(@request, opts) == failure(error)
      refute_received :registered
    end
  end

  test "adapter exit and registry failure are unavailable, without retry" do
    opts = [
      observe: fn ->
        send(self(), :observed)
        exit(:timeout)
      end,
      registered: fn ->
        send(self(), :registered)
        MapSet.new()
      end
    ]

    assert Sessions.dispatch(@request, opts) == failure("sessions_unavailable")
    assert_received :observed
    refute_received :observed
    refute_received :registered

    opts = [
      observe: fn ->
        send(self(), :observed)
        {:ok, [row(1, "$1", 0, 0)]}
      end,
      registered: fn ->
        send(self(), :registered)
        raise ArgumentError, "private-registry"
      end
    ]

    assert Sessions.dispatch(@request, opts) == failure("sessions_unavailable")
    assert_received :observed
    assert_received :registered
    refute_received :observed
    refute_received :registered
  end

  test "the real registry read refuses an absent registry in an isolated BEAM" do
    # Never stop the suite's registry or start the product application in the child.
    probe = """
    {:ok, _} = Application.ensure_all_started(:opentelemetry_api)
    nil = Process.whereis(AiPair.Supervisor)
    {:ok, registry} = Registry.start_link(keys: :unique, name: AiPair.Registry)
    request = %{"cmd" => "sessions", "protocol_version" => 2}
    observe = fn -> {:ok, []} end
    %{"ok" => true, "protocol_version" => 2, "sessions" => []} =
      AiPair.IPC.Sessions.dispatch(request, observe: observe)
    :ok = Supervisor.stop(registry)
    nil = Process.whereis(AiPair.Registry)
    %{"ok" => false, "protocol_version" => 2, "error" => "sessions_unavailable"} =
      AiPair.IPC.Sessions.dispatch(request, observe: observe)
    nil = Process.whereis(AiPair.Supervisor)
    IO.puts("REGISTRY_ABSENCE_CONFIRMED")
    """

    paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)
    elixir = System.find_executable("elixir") || flunk("elixir is required")
    timeout = System.find_executable("timeout") || flunk("coreutils timeout is required")

    {output, status} =
      System.cmd(timeout, ["--kill-after=5s", "15s", elixir] ++ paths ++ ["-e", probe],
        stderr_to_stdout: true,
        env: [{"ERL_FLAGS", "+S 2:2 +A 1"}, {"ERL_AFLAGS", nil}]
      )

    assert status == 0, output
    assert output == "REGISTRY_ABSENCE_CONFIRMED\n"
  end

  test "request refusal precedes every observation; trace carrier keys are permitted" do
    opts = [
      observe: fn ->
        send(self(), :observed)
        {:ok, []}
      end,
      registered: fn ->
        send(self(), :registered)
        MapSet.new()
      end
    ]

    for request <- [
          Map.put(@request, "project", "private"),
          Map.put(@request, "protocol_version", 1),
          %{}
        ] do
      assert Sessions.dispatch(request, opts) == failure("invalid_sessions_request")
      refute_received :observed
      refute_received :registered
    end

    assert Sessions.dispatch(Map.merge(@request, %{"traceparent" => "", "tracestate" => ""}), opts)[
             "ok"
           ]

    assert_received :observed
    assert_received :registered
  end

  test "actual encoder admits the exact byte bound and substitutes the oversize reply above it" do
    base = reply_with_name("") |> Jason.encode!() |> byte_size()
    exact = reply_with_name(String.duplicate("a", @limit - base))
    over = reply_with_name(String.duplicate("a", @limit - base + 1))
    assert byte_size(Jason.encode!(exact)) == @limit
    assert byte_size(Jason.encode!(over)) == @limit + 1
    assert Sessions.encode_reply(exact) == Jason.encode!(exact)
    assert Sessions.encode_reply(over) |> Jason.decode!() == failure("oversize")

    unicode = reply_with_name(String.duplicate(<<0xC3, 0xA9>>, div(@limit - base, 2) + 1))
    assert String.length(Jason.encode!(unicode)) < @limit
    assert Sessions.encode_reply(unicode) |> Jason.decode!() == failure("oversize")
  end

  test "reply validation rejects malformed, unordered and conflicting public data" do
    reply = reply_with_name("valid")
    [session] = reply["sessions"]
    [address] = session["panes"]
    assert Sessions.valid_reply?(reply)

    bad_sessions = [
      [session, session],
      [Map.put(session, "session_name", "")],
      [Map.put(session, "session_name", <<255>>)],
      [Map.put(session, "panes", %{})],
      [Map.put(session, "panes", [address, address])],
      [Map.put(session, "panes", [Map.put(address, "pid", 1)])],
      [Map.put(session, "session_id", "$not-decimal")],
      [Map.put(session, "session_id", "$2"), Map.put(session, "session_id", "$1")],
      [
        session,
        Map.merge(session, %{
          "session_id" => "$2",
          "panes" => [Map.put(address, "registered_at_observation", true)]
        })
      ]
    ]

    for sessions <- bad_sessions do
      refute Sessions.valid_reply?(%{reply | "sessions" => sessions})
    end

    for error <- ~w(invalid_sessions_request invalid_sessions_census sessions_unavailable oversize) do
      assert Sessions.valid_reply?(failure(error))
    end

    refute Sessions.valid_reply?(failure("unknown"))
    refute Sessions.valid_reply?(Map.put(failure("oversize"), "diagnostic", "private"))
    refute Sessions.valid_reply?(Map.put(reply, "protocol_version", 1))
    refute Sessions.valid_reply?(Map.put(reply, "ok", "true"))
    refute Sessions.valid_reply?(nil)
  end

  defp reply_with_name(name) do
    %{
      "protocol_version" => 2,
      "ok" => true,
      "sessions" => [
        %{
          "session_id" => "$1",
          "session_name" => name,
          "panes" => [
            %{
              "pane_id" => pane(1),
              "window_index" => 0,
              "pane_index" => 0,
              "registered_at_observation" => false
            }
          ]
        }
      ]
    }
  end

  defp row(id, session, window, index) do
    %{
      pane_id: pane(id),
      session_id: session,
      session_name: "shared-name",
      window_index: window,
      pane_index: index,
      pane_pid: 42,
      command: "private-command",
      path: "/private-path"
    }
  end

  defp pane(id), do: "%" <> Integer.to_string(id)
  defp failure(error), do: %{"protocol_version" => 2, "ok" => false, "error" => error}
end
