defmodule AiPair.IPC.Rb3aPairingP2wTest.ManualTimer do
  @moduledoc false
  # A timer that never fires by itself: each arm is reported to the test process, which delivers
  # the timeout message explicitly. This module's own key; no other test module is needed.
  def arm(dest, ms, message) do
    ref = make_ref()
    send(:persistent_term.get({__MODULE__, :test}), {:armed, ref, dest, ms, message})
    ref
  end

  def cancel(_ref), do: :ok
end

defmodule AiPair.IPC.Rb3aPairingP2wTest do
  @moduledoc """
  RB-3a-P P2-W producer witnesses (scope D/rb/RB3A-PAIRING-SCOPE-r5.org; design
  D/rb/RB3A-P2W-DESIGN-r2.org, DESIGN GO m_20261008T220106Z). Test-only; the canonical vendored v3
  set (77 files) is unchanged.

    * W-T: with the configured bound 30_000 under an injected timer and an explicit trigger,
      quiesce answers the canonical quiesce.error.quiesce_timeout.json in full. This proves the
      configured wire bound, not default option selection or elapsed time.
    * W-P: a durable daemon with an admission (no fence held) answers ping with the two candidate
      replies in test/fixtures/rb3a_pairing_p2w/, in full, pong included, with and without a read
      build identity record. Controls: the same pings without an admission still answer the
      canonical ping.ok.identity_core_release[_build].json (durable dispatch without admission).

  The candidates are unpaired data outside the canonical set; quiesce.ok stays an example (Q0).
  """

  use ExUnit.Case, async: false

  alias AiPair.Delivery.ReceiptStore
  alias AiPair.IPC.DeliveryV3
  alias AiPair.IPC.Rb3aPairingP2wTest.ManualTimer

  @canonical Path.expand("../../fixtures/contracts/ipc/v3", __DIR__)
  @candidates Path.expand("../../fixtures/rb3a_pairing_p2w", __DIR__)
  @guard_ms 5_000
  @ping %{"cmd" => "ping", "protocol_version" => 3}

  setup do
    :persistent_term.put({ManualTimer, :test}, self())
    on_exit(fn -> :persistent_term.erase({ManualTimer, :test}) end)
    n = System.unique_integer([:positive])
    inbox = Path.join(canonical_tmp(), "rb3a-p2w-#{n}")
    File.mkdir_p!(inbox)
    File.chmod!(inbox, 0o700)
    on_exit(fn -> File.rm_rf!(inbox) end)
    store = start_supervised!({ReceiptStore, inbox: inbox})
    pis = start_supervised!({AiPair.PaneIntentStore, root: inbox})
    secret = :crypto.strong_rand_bytes(32)

    {:ok,
     store: store,
     pis: pis,
     hash: "sha256:" <> Base.encode16(:crypto.hash(:sha256, secret), case: :lower)}
  end

  defp admission(c, opts \\ []) do
    observe = fn ->
      AiPair.Admission.Observer.observe(%{
        receipt_store: c.store,
        pane_intent_store: c.pis,
        marker: fn -> {:ok, 1} end
      })
    end

    defaults = [bound_ms: 60_000, receipt_store: c.store, observe: observe]
    start_supervised!({AiPair.Admission, Keyword.merge(defaults, opts)})
  end

  defp context(c, admission) do
    %{
      receipt_store: c.store,
      durable: true,
      admission: admission,
      committed: fn _pane -> :none end,
      current_pid: fn _pane -> {:ok, 4242} end
    }
  end

  defp canonical(name), do: @canonical |> Path.join(name) |> File.read!() |> Jason.decode!()
  defp candidate(name), do: @candidates |> Path.join(name) |> File.read!() |> Jason.decode!()

  # decode; pong is the contract's placeholder only when it is this build's version
  defp normalized(reply) do
    decoded = reply |> Jason.encode!() |> Jason.decode!()

    if decoded["pong"] == AiPair.version(),
      do: Map.put(decoded, "pong", "<version>"),
      else: decoded
  end

  defp build_context(context),
    do:
      Map.put(
        context,
        :build_identity,
        canonical("ping.ok.identity_core_release_build.json")["build_identity"]
      )

  test "W-T quiesce_timeout at the configured bound 30000 is the canonical reply in full", c do
    adm = admission(c, bound_ms: 30_000, timer: ManualTimer)
    {:ok, held} = AiPair.Admission.enter(adm, :ipc_send)
    request = %{"cmd" => "quiesce", "protocol_version" => 3, "resume_hash" => c.hash}
    task = Task.async(fn -> DeliveryV3.dispatch(request, context(c, adm)) end)

    assert_receive {:armed, _ref, dest, 30_000, message}, @guard_ms
    assert Task.yield(task, 0) == nil
    send(dest, message)

    assert normalized(Task.await(task, @guard_ms)) ==
             canonical("quiesce.error.quiesce_timeout.json")

    assert AiPair.Admission.exit(adm, held) == :ok
  end

  test "W-P a durable daemon with an admission answers the release ping candidate in full", c do
    adm = admission(c)
    assert AiPair.Admission.fence(adm) == nil

    assert normalized(DeliveryV3.dispatch(@ping, context(c, adm))) ==
             candidate("ping.ok.identity_core_release_quiesce.json")
  end

  test "W-P a durable daemon with an admission answers the build ping candidate in full", c do
    adm = admission(c)
    assert AiPair.Admission.fence(adm) == nil

    assert normalized(DeliveryV3.dispatch(@ping, build_context(context(c, adm)))) ==
             candidate("ping.ok.identity_core_release_build_quiesce.json")
  end

  test "control: without an admission the durable release ping is the canonical one", c do
    assert normalized(DeliveryV3.dispatch(@ping, context(c, nil))) ==
             canonical("ping.ok.identity_core_release.json")
  end

  test "control: without an admission the durable build ping is the canonical one", c do
    assert normalized(DeliveryV3.dispatch(@ping, build_context(context(c, nil)))) ==
             canonical("ping.ok.identity_core_release_build.json")
  end

  # the pane-intent store refuses a root under a symlink (macOS /var); as quiesce_v3_red_test.exs
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
