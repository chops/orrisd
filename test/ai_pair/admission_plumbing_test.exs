defmodule AiPair.AdmissionPlumbingTest do
  @moduledoc """
  NS-32.M.002 RB-3a GREEN-1 rows answering source AMEND m_20261007T163700Z.

  P1 the payload dimension is the live payload store's own observation of its pinned directory
  (AiPair.Delivery.PayloadStore.observe/1, source AMEND m_20261007T165250Z): a directory that
  vanished, was replaced (another inode) or is unsafe (mode, symlink), or an entry of an unknown
  layout, makes the observation `{:error, "payloads"}` (quiesce answers observation_incomplete
  naming payloads); a live owner never certifies loss as no payload.

  P2 the admission reaches every path that starts a pane child: v1 attach binds the started
  child to the server's admission (runtime), and every child-option builder in lib (attach,
  release, boot reconciliation and readmit) goes through AiPair.Admission.child_opts/1 (static).
  The full runtime witness of each production path is guard G2, completed by GREEN-2.
  """

  use ExUnit.Case, async: false

  alias AiPair.Admission.Observer
  alias AiPair.Delivery.ReceiptStore
  alias AiPair.Test.RouteGuard

  @guard_ms 5_000

  setup do
    RouteGuard.install!()
    n = System.unique_integer([:positive])
    inbox = Path.join(canonical_tmp(), "rb3a-plumb-#{n}")
    File.mkdir_p!(inbox)
    File.chmod!(inbox, 0o700)
    on_exit(fn -> File.rm_rf!(inbox) end)
    store = start_supervised!({ReceiptStore, inbox: inbox})
    pis = start_supervised!({AiPair.PaneIntentStore, root: inbox})
    {:ok, n: n, inbox: inbox, store: store, pis: pis}
  end

  defp observe(c) do
    Observer.observe(%{
      receipt_store: c.store,
      pane_intent_store: c.pis,
      marker: fn -> {:ok, 1} end
    })
  end

  defp payload_dir(c), do: Path.join([c.inbox, "delivery", "payloads"])

  @object "snd_" <> String.duplicate("a", 64) <> ".1." <> String.duplicate("b", 64) <> ".payload"

  test "P1 the pinned payload directory is observed: empty, then holding an object", c do
    assert {:ok, %{"payloads" => %{"layouts" => []}}} = observe(c)
    File.write!(Path.join(payload_dir(c), ".tmp-0123456789abcdef"), "x")
    assert {:ok, %{"payloads" => %{"layouts" => []}}} = observe(c)
    File.write!(Path.join(payload_dir(c), @object), "x")
    assert {:ok, %{"payloads" => %{"layouts" => [1]}}} = observe(c)
  end

  test "P1 a payload directory that vanished during the daemon's life is refused, never no payload",
       c do
    File.rm_rf!(payload_dir(c))
    assert observe(c) == {:error, "payloads"}
  end

  test "P1 a replaced payload directory (same path, another inode) is refused", c do
    # the pinned directory is kept aside (still allocated) so the new one cannot reuse its inode
    File.rename!(payload_dir(c), payload_dir(c) <> ".aside")
    File.mkdir_p!(payload_dir(c))
    File.chmod!(payload_dir(c), 0o700)
    assert observe(c) == {:error, "payloads"}
  end

  test "P1 an unsafe payload directory (mode, or a symlink in its place) is refused", c do
    File.chmod!(payload_dir(c), 0o755)
    assert observe(c) == {:error, "payloads"}
    File.chmod!(payload_dir(c), 0o700)
    assert {:ok, _} = observe(c)

    aside = payload_dir(c) <> ".aside"
    File.rename!(payload_dir(c), aside)
    File.ln_s!(aside, payload_dir(c))
    assert observe(c) == {:error, "payloads"}
  end

  test "P1 an entry of an unknown layout makes the observation incomplete at payloads", c do
    File.write!(Path.join(payload_dir(c), "not-a-payload"), "x")
    assert observe(c) == {:error, "payloads"}
  end

  test "P2 a v1 attach starts the pane child bound to the server's admission", c do
    sock_dir = Path.join(c.inbox, "sock")
    File.mkdir_p!(sock_dir)
    File.chmod!(sock_dir, 0o700)

    {:ok, adm} =
      AiPair.Admission.start_link(
        bound_ms: 60_000,
        receipt_store: c.store,
        observe: fn -> {:ok, %{}} end
      )

    start_supervised!(
      {AiPair.IPC.Server,
       inbox: c.inbox, name: :"rb3a_plumb_server_#{c.n}", receipt_store: c.store, admission: adm}
    )

    pane = "%rb3a_plumb_#{c.n}"
    :ok = RouteGuard.own_pane(pane)

    reply =
      request(Path.join(sock_dir, "ai-pair.sock"), %{"cmd" => "attach_pane", "pane_id" => pane})

    assert reply["ok"] == true
    on_exit(fn -> AiPair.PaneSupervisor.stop_pane(pane) end)

    assert {:ok, pid} = AiPair.PaneSupervisor.whereis_pane(pane)
    {_state, data} = :sys.get_state(pid)
    assert data.admission == adm
  end

  test "P2 every child-option builder in lib binds the admission through child_opts/1" do
    lib = Path.expand("../../lib/ai_pair", __DIR__)
    server = File.read!(Path.join(lib, "ipc/server.ex"))
    reconciler = File.read!(Path.join(lib, "pane_restore/reconciler.ex"))

    # attach (v1 and durable) and release build their options in the server
    assert server =~
             "defp admission_opts(context), do: AiPair.Admission.child_opts(context[:admission])"

    assert length(Regex.scan(~r/admission_opts\(context\)/, server)) >= 4
    assert server =~ "] ++ AiPair.Admission.child_opts(admission)}"
    assert server =~ "pane_opts: fn pane -> released_pane_opts(pane, context[:admission]) end"

    # boot reconciliation and readmit build theirs in the reconciler
    assert reconciler =~ "] ++ restore ++ AiPair.Admission.child_opts(admission)"

    assert length(
             Regex.scan(
               ~r/child_spec\(pane, callbacks, [a-z_]+, registration_id, admission\)/,
               reconciler
             )
           ) == 2

    assert AiPair.Admission.child_opts(nil) == []
    assert AiPair.Admission.child_opts(:adm) == [admission: :adm]
  end

  defp request(sock, payload) do
    {:ok, client} =
      :gen_tcp.connect({:local, sock}, 0, [:binary, {:active, false}, {:packet, 4}], 1_000)

    :ok = :gen_tcp.send(client, Jason.encode!(payload))
    {:ok, frame} = :gen_tcp.recv(client, 0, @guard_ms)
    :gen_tcp.close(client)
    Jason.decode!(frame)
  end

  # the pane-intent store refuses a root under a symlink (macOS /var); as pane_intent_store_test.exs
  defp canonical_tmp do
    System.tmp_dir!()
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce("/", fn seg, acc ->
      joined = Path.join(acc, seg)

      case File.read_link(joined) do
        {:ok, "/" <> _ = absolute} -> absolute
        {:ok, relative} -> Path.expand(Path.join(Path.dirname(joined), relative))
        {:error, _} -> joined
      end
    end)
  end
end
