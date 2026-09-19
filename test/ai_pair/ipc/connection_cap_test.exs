defmodule AiPair.IPC.ConnectionCapTest do
  @moduledoc """
  The bound on concurrently live IPC connection handlers, observed refusing.

  The defect this closes is T-22 of `phase0/mcp-threat-model.org` in the
  planning repository: `AiPair.Application` started
  `AiPair.IPC.ConnectionSupervisor` as a bare `Task.Supervisor` with no
  `max_children`, so a local process that opened connections in a loop and sent
  no frame held one handler task and one socket each -- for
  `AiPair.IPC.Server`'s five-second handler receive timeout -- and nothing
  refused the next one. Frames were capped, send text was capped, the handler
  wait was capped; the COUNT was not.

  What these rows pin:

    * the running supervisor carries the cap `AiPair.IPC.Server` declares, so
      the composition and the number cannot drift apart silently;
    * with the cap taken, the next connection is REFUSED -- the daemon closes
      it without a reply -- rather than queued behind a slot that may never
      free. The distinction is the whole of the control: a queued connection is
      an unbounded resource with a politer name;
    * a refused connection consumes no slot, and a released slot admits a fresh
      connection again, so the cap is a bound and not a one-way latch.

  ANTI-VACUITY is carried by the first exchange: one ordinary `ping` is
  answered on this socket BEFORE the cap is taken, so a refusal afterwards is
  the cap refusing and not a server that never served.

  Route containment: the file installs `AiPair.Test.RouteGuard` because it
  starts a real IPC server. No row here attaches a pane, so no capture route is
  reachable, but a row added later that does would otherwise reach the
  operator's own tmux server.
  """

  use ExUnit.Case, async: false

  alias AiPair.Test.ReceiptBackedIPCServer, as: Server
  alias AiPair.Test.RouteGuard

  @connection_supervisor AiPair.IPC.ConnectionSupervisor
  @settle_ms 2_000

  setup do
    RouteGuard.install!()

    tmp = Path.join(System.tmp_dir!(), "ai_pair_cap_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "sock"))
    File.chmod!(Path.join(tmp, "sock"), 0o700)
    on_exit(fn -> File.rm_rf!(tmp) end)

    # Every row counts this supervisor's children, so a handler left over from
    # an earlier suite would be counted as one of ours.
    wait_for_children(0)

    {:ok, inbox: tmp, sock_path: Path.join(tmp, "sock/ai-pair.sock")}
  end

  test "the running connection supervisor carries the cap the IPC server declares" do
    # `max_concurrent_connections/0` is specced `pos_integer()`, so a row
    # asserting it is one would be a check the compiler already proved and
    # therefore a check that cannot fail. What CAN differ is whether the
    # composition passed it to the supervisor at all, which is what follows.
    cap = AiPair.IPC.Server.max_concurrent_connections()

    supervisor = Process.whereis(@connection_supervisor)
    assert is_pid(supervisor), "the application did not start #{inspect(@connection_supervisor)}"

    state = :sys.get_state(supervisor)

    assert Map.has_key?(state, :max_children),
           "the connection supervisor's state no longer carries :max_children; re-derive " <>
             "how this bound is observed rather than deleting the row"

    assert Map.get(state, :max_children) == cap,
           "the running supervisor's bound is #{inspect(Map.get(state, :max_children))} but " <>
             "AiPair.IPC.Server declares #{cap}. The composition in " <>
             "lib/ai_pair/application.ex must pass max_concurrent_connections/0 and nothing else"
  end

  test "a connection beyond the cap is refused, not queued", %{
    inbox: inbox,
    sock_path: sock_path
  } do
    cap = AiPair.IPC.Server.max_concurrent_connections()

    {:ok, pid} = Server.start_link(inbox: inbox, name: :ipc_connection_cap)
    on_exit(fn -> stop_quietly(pid) end)

    # ANTI-VACUITY: this socket serves before the cap is taken.
    assert %{"ok" => true, "pong" => version} = one_shot(sock_path)
    assert is_binary(version)
    wait_for_children(0)

    # Take the whole cap with connections that send nothing, one at a time, so
    # that the listen backlog is never the thing under test and each handler is
    # observed to exist before the next connection is opened.
    held =
      for n <- 1..cap do
        client = connect(sock_path)
        wait_for_children(n)
        client
      end

    # The acceptor accepts this one, `Task.Supervisor.start_child/2` answers
    # {:error, :max_children}, and `accept_loop/3` closes the client socket.
    refused = connect(sock_path)
    :ok = :gen_tcp.send(refused, ~s({"cmd":"ping"}))

    assert {:error, :closed} = :gen_tcp.recv(refused, 0, @settle_ms),
           "the connection beyond max_children was answered, so no cap was applied"

    # Refused while the cap is still fully taken: a QUEUED connection would
    # still be open here, waiting for a slot that nothing promises will free.
    assert children() == cap,
           "a refused connection must consume no slot, but the supervisor now holds " <>
             "#{children()} of #{cap}"

    :gen_tcp.close(refused)

    # And the cap is a bound, not a latch: release one slot and the surface
    # serves a fresh connection again.
    [first | rest] = held
    :gen_tcp.close(first)
    wait_for_children(cap - 1)

    assert %{"ok" => true} = one_shot(sock_path)

    Enum.each(rest, &:gen_tcp.close/1)
    wait_for_children(0)
  end

  # ===== helpers =====

  defp children, do: @connection_supervisor |> Task.Supervisor.children() |> length()

  defp wait_for_children(expected) do
    wait_for_children(expected, System.monotonic_time(:millisecond) + @settle_ms)
  end

  defp wait_for_children(expected, deadline) do
    actual = children()

    cond do
      actual == expected ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("connection supervisor settled at #{actual} handlers, expected #{expected}")

      true ->
        Process.sleep(5)
        wait_for_children(expected, deadline)
    end
  end

  defp connect(sock_path) do
    {:ok, client} =
      :gen_tcp.connect({:local, sock_path}, 0, [:binary, {:active, false}, {:packet, 4}], 1_000)

    client
  end

  defp one_shot(sock_path) do
    client = connect(sock_path)
    :ok = :gen_tcp.send(client, ~s({"cmd":"ping"}))
    {:ok, frame} = :gen_tcp.recv(client, 0, @settle_ms)
    :gen_tcp.close(client)
    Jason.decode!(frame)
  end

  # The listener closes its acceptor on the way down and answers `:shutdown`
  # rather than `:normal`; the sibling IPC suites take the same precaution.
  defp stop_quietly(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end
  end
end
