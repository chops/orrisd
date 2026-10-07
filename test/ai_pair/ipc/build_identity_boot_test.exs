defmodule AiPair.IPC.BuildIdentityBootTest do
  @moduledoc """
  NS-32.M.001 RB-1 C2: the daemon reads its build identity once, when the IPC server starts.

  The server reads `<release_root>/share/ai-pair/build-identity.json` through
  `AiPair.BuildIdentity.read/1`, with `release_root` taken from the `:release_root` application
  env (default: the running release's root). The supervision child list is not changed, because it
  is frozen by the durable-mode configuration contract.

  - A valid record is reported by the version 3 ping over the real socket.
  - A refused record is logged once as a warning beginning "build_identity refused:", which names
    the reason. The server still starts, and the ping carries no token.
  - An absent record is not logged. The server starts, and the ping carries no token.
  - The record is read once. A file changed after start does not change the ping.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AiPair.Test.ReceiptBackedIPCServer, as: Server

  @fixtures Path.expand("../../fixtures/contracts/ipc/v3", __DIR__)

  setup do
    tmp = Path.join(System.tmp_dir!(), "ai_pair_build_id_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "inbox/sock"))
    File.chmod!(Path.join(tmp, "inbox/sock"), 0o700)
    release = Path.join(tmp, "release")
    File.mkdir_p!(Path.join(release, "share/ai-pair"))

    # The server hands each connection to the application's connection supervisor; start one
    # only where no application is running (a bare ExUnit run).
    unless Process.whereis(AiPair.IPC.ConnectionSupervisor) do
      start_supervised!({Task.Supervisor, name: AiPair.IPC.ConnectionSupervisor})
    end

    previous = Application.fetch_env(:ai_pair, :release_root)
    Application.put_env(:ai_pair, :release_root, release)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ai_pair, :release_root, value)
        :error -> Application.delete_env(:ai_pair, :release_root)
      end

      File.rm_rf!(tmp)
    end)

    inbox = Path.join(tmp, "inbox")
    {:ok, inbox: inbox, release: release, sock_path: Path.join(inbox, "sock/ai-pair.sock")}
  end

  test "B1 a valid record is reported by the version 3 ping over the socket", c do
    record = record("ping.ok.identity_core_release_build.json")
    write_record(c, Jason.encode!(record))

    start_server(c, :build_id_b1)
    reply = ping(c)

    assert "build_identity" in reply["capabilities"]
    assert reply["build_identity"] == record
  end

  test "B2 a refused record is logged once, the server starts, and ping has no token", c do
    valid = record("ping.ok.identity_core_release_build.json")
    write_record(c, Jason.encode!(Map.put(valid, "built_at", "2026-10-07")))

    log = capture_log(fn -> start_server(c, :build_id_b2) end)

    refusals =
      log |> String.split("\n") |> Enum.filter(&String.contains?(&1, "build_identity refused:"))

    assert length(refusals) == 1
    assert [line] = refusals
    assert line =~ "[warning]"
    assert line =~ "built_at"

    reply = ping(c)
    refute "build_identity" in reply["capabilities"]
    refute Map.has_key?(reply, "build_identity")
  end

  test "B3 an absent record is not logged, the server starts, and ping has no token", c do
    log = capture_log(fn -> start_server(c, :build_id_b3) end)
    refute log =~ "build_identity"

    reply = ping(c)
    refute "build_identity" in reply["capabilities"]
    refute Map.has_key?(reply, "build_identity")
  end

  test "B4 the record is read once: a file changed after start does not change the ping", c do
    clean = record("ping.ok.identity_core_release_build.json")
    write_record(c, Jason.encode!(clean))
    start_server(c, :build_id_b4)

    write_record(c, Jason.encode!(record("ping.ok.identity_core_release_build_dirty.json")))
    assert ping(c)["build_identity"] == clean
  end

  defp start_server(c, name) do
    {:ok, pid} = Server.start_link(inbox: c.inbox, name: name)
    on_exit(fn -> stop_quietly(pid) end)
    pid
  end

  defp ping(c) do
    {:ok, client} =
      :gen_tcp.connect({:local, c.sock_path}, 0, [:binary, {:active, false}, {:packet, 4}], 1_000)

    :ok = :gen_tcp.send(client, ~s({"cmd":"ping","protocol_version":3}))
    {:ok, frame} = :gen_tcp.recv(client, 0, 1_000)
    :gen_tcp.close(client)
    Jason.decode!(frame)
  end

  defp record(name),
    do:
      @fixtures
      |> Path.join(name)
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("build_identity")

  defp write_record(c, bytes),
    do: File.write!(Path.join(c.release, "share/ai-pair/build-identity.json"), bytes)

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
