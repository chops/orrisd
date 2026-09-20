defmodule AiPair.IPC.SessionsSocketTest do
  use ExUnit.Case, async: false

  alias AiPair.Delivery.ReceiptStore
  alias AiPair.IPC.Server
  alias AiPair.Test.RouteGuard

  @request %{"cmd" => "sessions", "protocol_version" => 2}
  @limit 1_048_576

  defmodule Census do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

    @impl true
    def init(owner), do: {:ok, %{owner: owner, result: {:ok, []}, calls: []}}

    @impl true
    def handle_call({:result, result}, _from, state),
      do: {:reply, :ok, %{state | result: result}}

    def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}

    def handle_call(request, _from, state) do
      send(state.owner, {:census_call, request})
      result = if request == :observe_panes, do: state.result, else: {:error, :unexpected_operation}
      {:reply, result, %{state | calls: [request | state.calls]}}
    end
  end

  setup do
    RouteGuard.install!()
    root = Path.join(System.tmp_dir!(), "sessions_ipc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "sock"))
    File.chmod!(Path.join(root, "sock"), 0o700)
    previous = Application.fetch_env(:ai_pair, :tmux_server)
    adapter = start_supervised!({Census, self()})
    Application.put_env(:ai_pair, :tmux_server, adapter)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ai_pair, :tmux_server, value)
        :error -> Application.delete_env(:ai_pair, :tmux_server)
      end

      File.rm_rf!(root)
    end)

    store = start_supervised!({ReceiptStore, inbox: root})

    start_supervised!(
      {Server, inbox: root, name: :sessions_socket_test, receipt_store: store, boot_generation: "1"}
    )

    %{root: root, socket: Path.join(root, "sock/ai-pair.sock"), adapter: adapter, store: store}
  end

  test "real v2 route observes once and snapshots actual registration without effects", context do
    registered = pane(9001)
    {:ok, _} = Registry.register(AiPair.Registry, {:pane, registered}, :sessions_test)
    rows = [row(9001, "$2", 10, 0), row(9002, "$10", 0, 2), row(9001, "$2", 2, 0)]
    set_census(context, {:ok, rows})
    before = effects(context)

    assert %{"protocol_version" => 2, "ok" => true, "sessions" => [first, second]} =
             request(context.socket, @request)

    assert first == %{
             "session_id" => "$10",
             "session_name" => "public-name",
             "panes" => [address(9002, 0, 2, false)]
           }

    assert second == %{
             "session_id" => "$2",
             "session_name" => "public-name",
             "panes" => [address(9001, 2, 0, true), address(9001, 10, 0, true)]
           }

    assert GenServer.call(context.adapter, :calls) == [:observe_panes]
    assert effects(context) == before
    assert RouteGuard.violations() == []
  end

  test "ordinary ping advertises sessions without reading the census", context do
    reply = request(context.socket, %{"cmd" => "ping", "protocol_version" => 2})
    assert reply["capabilities"] == ["delivery_reconcile", "sessions_read"]
    assert GenServer.call(context.adapter, :calls) == []
  end

  test "invalid requests and explicit v1 are refused before census", context do
    before = effects(context)

    for extra <- [%{"project" => "private"}, %{"refresh" => true}] do
      assert request(context.socket, Map.merge(@request, extra)) ==
               failure("invalid_sessions_request")
    end

    assert %{"ok" => false} = request(context.socket, Map.put(@request, "protocol_version", 1))
    assert GenServer.call(context.adapter, :calls) == []
    assert effects(context) == before
    assert RouteGuard.violations() == []
  end

  test "empty observation and stopped adapter are distinct wire outcomes", context do
    assert request(context.socket, @request) == %{
             "protocol_version" => 2,
             "ok" => true,
             "sessions" => []
           }

    assert GenServer.call(context.adapter, :calls) == [:observe_panes]
    stop_supervised!(Census)
    assert request(context.socket, @request) == failure("sessions_unavailable")
    assert RouteGuard.violations() == []
  end

  test "malformed census refuses the whole reply with a static error", context do
    for result <- [
          {:error, {:malformed_pid, "private-pid"}},
          {:ok, [row(9001, "$1", 0, 0), row(9002, "$1", 0, 0)]},
          {:ok, [row(9001, "$1", 0, 0), %{row(9002, "$1", 0, 1) | session_name: "conflict"}]}
        ] do
      set_census(context, result)
      assert request(context.socket, @request) == failure("invalid_sessions_census")
    end

    assert GenServer.call(context.adapter, :calls) == List.duplicate(:observe_panes, 3)
  end

  test "actual socket payload admits exactly the cap and sends only refusal above it", context do
    base = %{
      "protocol_version" => 2,
      "ok" => true,
      "sessions" => [
        %{"session_id" => "$1", "session_name" => "", "panes" => [address(9001, 0, 0, false)]}
      ]
    }

    padding = @limit - byte_size(Jason.encode!(base))

    set_census(
      context,
      {:ok, [%{row(9001, "$1", 0, 0) | session_name: String.duplicate("a", padding)}]}
    )

    exact = frame(context.socket, @request)
    assert byte_size(exact) == @limit
    assert Jason.decode!(exact)["ok"] == true

    set_census(
      context,
      {:ok, [%{row(9001, "$1", 0, 0) | session_name: String.duplicate("a", padding + 1)}]}
    )

    refused = frame(context.socket, @request)
    assert Jason.decode!(refused) == failure("oversize")
    assert byte_size(refused) < 100
    assert GenServer.call(context.adapter, :calls) == [:observe_panes, :observe_panes]
  end

  defp set_census(context, result), do: GenServer.call(context.adapter, {:result, result})

  defp effects(context) do
    %{
      registry:
        Registry.select(AiPair.Registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
        |> Enum.sort(),
      panes: DynamicSupervisor.which_children(AiPair.PaneSupervisor) |> Enum.sort(),
      receipt_state: :sys.get_state(context.store),
      receipt_bytes: context.store |> ReceiptStore.path() |> File.read!()
    }
  end

  defp request(socket, payload), do: socket |> frame(payload) |> Jason.decode!()

  defp frame(socket, payload) do
    {:ok, client} =
      :gen_tcp.connect({:local, socket}, 0, [:binary, active: false, packet: 4], 1_000)

    try do
      :ok = :gen_tcp.send(client, Jason.encode!(payload))
      {:ok, bytes} = :gen_tcp.recv(client, 0, 3_000)
      assert {:error, :closed} = :gen_tcp.recv(client, 0, 1_000)
      bytes
    after
      :gen_tcp.close(client)
    end
  end

  defp row(id, session, window, index) do
    %{
      pane_id: pane(id),
      session_id: session,
      session_name: "public-name",
      window_index: window,
      pane_index: index,
      pane_pid: 42,
      command: "private-command",
      path: "/private-path"
    }
  end

  defp address(id, window, index, registered) do
    %{
      "pane_id" => pane(id),
      "window_index" => window,
      "pane_index" => index,
      "registered_at_observation" => registered
    }
  end

  defp pane(id), do: "%" <> Integer.to_string(id)
  defp failure(reason), do: %{"protocol_version" => 2, "ok" => false, "error" => reason}
end
