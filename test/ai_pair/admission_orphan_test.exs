defmodule AiPair.AdmissionOrphanTest do
  @moduledoc """
  NS-32.M.002 RB-3a GREEN-2, design r4 W6: a ticket whose holder exits before returning it is
  ORPHANED, listed by Admission.outstanding/1 and never released by Admission (the effect the
  holder started may still run). Every later quiesce answers quiesce_timeout with the bound and
  reopens; ordinary enters stay admitted. Also outstanding/1's live entries and the bound
  validation at start.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AiPair.Admission

  @hash "sha256:" <> String.duplicate("0", 64)

  defmodule TestTimer do
    @moduledoc false
    # Records the arm request and never fires by itself; the test delivers the bound message.
    def arm(server, ms, message) do
      send(:persistent_term.get({__MODULE__, :test}), {:armed, server, ms, message})
      make_ref()
    end

    def cancel(_ref), do: :ok
  end

  setup do
    :persistent_term.put({TestTimer, :test}, self())
    on_exit(fn -> :persistent_term.erase({TestTimer, :test}) end)

    {:ok, adm} =
      Admission.start_link(bound_ms: 1_000, timer: TestTimer, observe: fn -> {:ok, %{}} end)

    {:ok, adm: adm}
  end

  defp holder!(adm, kind) do
    me = self()

    pid =
      spawn(fn ->
        {:ok, _} = Admission.enter(adm, kind)
        send(me, {:holding, self()})
        Process.sleep(:infinity)
      end)

    assert_receive {:holding, ^pid}
    pid
  end

  test "outstanding lists each live ticket with its kind and holder", %{adm: adm} do
    a = holder!(adm, :ipc_send)
    b = holder!(adm, :idle_paste)
    assert Admission.outstanding(adm) == Enum.sort([{:ipc_send, a}, {:idle_paste, b}])
    Enum.each([a, b], &Process.exit(&1, :kill))
  end

  test "a holder that exits leaves an orphan, never released; quiesce times out with the bound and reopens",
       %{adm: adm} do
    holder = holder!(adm, :idle_paste)
    ref = Process.monitor(holder)

    log =
      capture_log(fn ->
        Process.exit(holder, :kill)
        assert_receive {:DOWN, ^ref, :process, ^holder, :killed}
        # The DOWN reaches Admission before this call (both from the same exit, in order).
        _ = :sys.get_state(adm)
      end)

    assert log =~ "idle_paste ticket holder exited; ticket orphaned"
    assert Admission.outstanding(adm) == [{:idle_paste, holder, :orphaned}]

    waiter = Task.async(fn -> Admission.quiesce(adm, @hash) end)
    assert_receive {:armed, ^adm, 1_000, {:drain_bound, token}}
    send(adm, {:drain_bound, token})
    assert Task.await(waiter) == {:error, {:quiesce_timeout, 1_000}}

    # Reopened for ordinary work, and the orphan is still there.
    assert {:ok, ticket} = Admission.enter(adm, :ipc_send)
    :ok = Admission.exit(adm, ticket)
    assert Admission.outstanding(adm) == [{:idle_paste, holder, :orphaned}]
  end

  test "an orphaned ticket cannot be returned by a process holding its reference", %{adm: adm} do
    me = self()

    # The holder hands its ticket reference to the test, then dies.
    holder =
      spawn(fn ->
        {:ok, ticket} = Admission.enter(adm, :ipc_send)
        send(me, {:ticket, self(), ticket})
        Process.sleep(:infinity)
      end)

    assert_receive {:ticket, ^holder, ticket}
    ref = Process.monitor(holder)
    capture_log(fn -> Process.exit(holder, :kill) end)
    assert_receive {:DOWN, ^ref, :process, ^holder, :killed}
    _ = :sys.get_state(adm)

    assert Admission.exit(adm, ticket) == {:error, :orphaned}
    assert Admission.outstanding(adm) == [{:ipc_send, holder, :orphaned}]

    # So a quiesce still cannot complete its drain.
    waiter = Task.async(fn -> Admission.quiesce(adm, @hash) end)
    assert_receive {:armed, ^adm, 1_000, {:drain_bound, token}}
    send(adm, {:drain_bound, token})
    assert Task.await(waiter) == {:error, {:quiesce_timeout, 1_000}}
  end

  test "a live ticket is returned only by its holder", %{adm: adm} do
    me = self()

    holder =
      spawn(fn ->
        {:ok, ticket} = Admission.enter(adm, :release)
        send(me, {:ticket, self(), ticket})

        receive do
          :return -> send(me, {:returned, Admission.exit(adm, ticket)})
        end
      end)

    assert_receive {:ticket, ^holder, ticket}
    assert Admission.exit(adm, ticket) == {:error, :not_holder}
    assert Admission.outstanding(adm) == [{:release, holder}]

    send(holder, :return)
    assert_receive {:returned, :ok}
    assert Admission.outstanding(adm) == []
  end

  test "a ticket returned normally leaves nothing outstanding and no orphan", %{adm: adm} do
    {:ok, ticket} = Admission.enter(adm, :attach_pane)
    :ok = Admission.exit(adm, ticket)
    assert Admission.outstanding(adm) == []
  end

  test "a drain bound that is not a positive integer refuses to start" do
    Process.flag(:trap_exit, true)

    for bad <- [0, -1, "30000", nil] do
      assert {:error, {:invalid_quiesce_bound_ms, ^bad}} = Admission.start_link(bound_ms: bad)
    end
  end
end
