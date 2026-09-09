defmodule AiPair.CaptureTimeoutTest do
  use ExUnit.Case, async: true

  alias AiPair.Tmux
  alias AiPair.Pane.StateMachine

  defmodule StalledCapture do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, {:stalled, [], Keyword.get(opts, :owner)}}

    def handle_call({:capture_pane, _, _}, from, {:stalled, callers, owner}) do
      if owner, do: send(owner, :capture_started)
      {:noreply, {:stalled, [from | callers], owner}}
    end

    def handle_call({:capture_pane, _, _}, _from, :ready), do: {:reply, {:ok, "ready"}, :ready}

    def handle_cast(:recover, {:stalled, callers, _owner}) do
      Enum.each(callers, &GenServer.reply(&1, {:ok, "late"}))
      {:noreply, :ready}
    end
  end

  test "a read-only capture timeout is data and the backend can recover" do
    server = start_supervised!(StalledCapture)

    result =
      try do
        Tmux.capture_pane("%probe", [], server)
      catch
        :exit, _ -> :uncaught_exit
      end

    assert {:error, %{status: 124, stderr: "tmux capture request timed out"}} = result
    assert Process.alive?(server)
    GenServer.cast(server, :recover)
    assert {:ok, "ready"} = Tmux.capture_pane("%probe", [], server)
    assert List.to_integer(:erlang.system_info(:otp_release)) >= 24
    refute_receive {_ref, {:ok, "late"}}, 50
  end

  test "a missing capture backend is not a dead pane" do
    server = start_supervised!(StalledCapture)
    stop_supervised!(StalledCapture)

    result =
      try do
        Tmux.capture_pane("%probe", [], server)
      catch
        :exit, _ -> :uncaught_exit
      end

    assert {:error, %{status: 125, stderr: "tmux capture backend unavailable"}} = result
  end

  test "real capture timeout preserves the pane owner and atomic queue snapshot" do
    server = start_supervised!({StalledCapture, owner: self()})

    pane =
      start_supervised!(%{
        id: StateMachine,
        start:
          {StateMachine, :start_link,
           [
             [
               pane_id: "%probe",
               capture_fn: &Tmux.capture_pane(&1, [], server),
               poll_interval_ms: 60_000
             ]
           ]}
      })

    assert_receive :capture_started, 1_000
    assert %{state: :unknown, pending_count: 0} = StateMachine.status(pane)
    assert Process.alive?(pane)
    assert {:queued, :unknown} = StateMachine.send_text(pane, "notification")
    assert %{state: :unknown, pending_count: 1} = StateMachine.status(pane)
  end
end
