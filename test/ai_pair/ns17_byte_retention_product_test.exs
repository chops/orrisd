defmodule AiPair.NS17ByteRetentionProductTest.ReportForward do
  @moduledoc false

  # `:logger` handler used only by F1-R3. It forwards each raw log event, before
  # any formatter or Elixir translation, to the pid in its handler config. It
  # formats nothing and writes nothing.
  def log(event, %{config: %{pid: pid}}) do
    send(pid, {:ns17p_log, event})
    :ok
  end
end

defmodule AiPair.NS17ByteRetentionProductTest do
  @moduledoc """
  RED rows for the NS-17 byte-retention product scope (r3, section 4).

  Only row F1-R3 is authored here. The other rows of that scope are not released
  and are not in this file.

  F1-R3: after a pane state machine has classified a screen that carries a
  token-shaped canary, its gen_statem terminate report must not carry the canary
  in the report's `:state`. The report is read RAW, through a `:logger` handler
  this test adds for the row, not through the translated log text.

  Expected at the base head: RED on the named leak assertion, because the state
  machine keeps the last raw capture in `last_capture`. The expected message is
  `F1-R3 canary found in: ["terminate report state"]`. Every control runs before
  that assertion, so a harness failure never looks like a leak or a pass.

  Report shape measured by PF-1 under the pinned toolchain: label
  `{:gen_statem, :terminate}`, domain `[:otp]`, level `:error` (it passes the
  suite's `:warning` primary level), and `:state` as a two-tuple whose first
  element is the state name. This row asserts the parts it relies on as
  controls.
  """

  use ExUnit.Case, async: false

  alias AiPair.NS17ByteRetentionProductTest.ReportForward
  alias AiPair.Pane.StateMachine

  @poll_interval_ms 5
  @captures_after_canary 3
  @wait_timeout_ms 2_000
  @report_timeout_ms 1_000

  describe "F1-R3 gen_statem terminate report" do
    test "the terminate report state carries no pane capture bytes" do
      n = System.unique_integer([:positive])
      canary = canary()
      assert byte_size(canary) >= 27

      pane_id = "%ns17p_" <> Integer.to_string(n)
      agent_marker = control_marker()
      stop_marker = control_marker()

      # The capture double reads its screen and counts its calls in an Agent.
      # The closure holds only the Agent pid, never the canary.
      screen = start_supervised!({Agent, fn -> {"IDLE_MARKER\n", 0} end}, id: {:screen, n})

      capture_fn = fn _pane ->
        Agent.get_and_update(screen, fn {bytes, count} -> {{:ok, bytes}, {bytes, count + 1}} end)
      end

      handler_id = String.to_atom("ns17p_f1r3_" <> Integer.to_string(n))
      handler_config = %{level: :all, config: %{pid: self()}}
      :ok = :logger.add_handler(handler_id, ReportForward, handler_config)
      on_exit(fn -> :logger.remove_handler(handler_id) end)

      {:ok, sm} =
        StateMachine.start_link(
          pane_id: pane_id,
          agent: agent_marker,
          capture_fn: capture_fn,
          paste_fn: fn _pane, _bytes -> :ok end,
          classifier: AiPair.Test.MarkerClassifier,
          poll_interval_ms: @poll_interval_ms
        )

      on_exit(fn -> if Process.alive?(sm), do: Process.exit(sm, :kill) end)

      Agent.update(screen, fn _ -> {"IDLE_MARKER\n" <> canary, 0} end)

      # Controls: the canary screen really was captured, and classified, by the
      # machine whose report is read below.
      assert wait_until(fn -> Agent.get(screen, &elem(&1, 1)) >= @captures_after_canary end),
             "F1-R3 control: too few captures after the canary was set"

      assert StateMachine.state(sm) == :idle,
             "F1-R3 control: the canary screen was not classified idle"

      Process.unlink(sm)

      assert :sys.terminate(sm, {:ns17p_stop, stop_marker}) == :ok,
             "F1-R3 control: sys.terminate did not return :ok"

      report = await_terminate_report()

      assert Map.has_key?(report, :state), "F1-R3 control: terminate report has no :state key"

      whole = render(report)

      assert String.contains?(whole, stop_marker),
             "F1-R3 control: the stop reason marker is not in the terminate report"

      assert String.contains?(whole, agent_marker),
             "F1-R3 control: the agent control marker is not in the terminate report"

      sinks = [{"terminate report state", render(report.state)}]
      leaks = for {name, hay} <- sinks, hit?(hay, canary), do: name

      assert leaks == [], "F1-R3 canary found in: " <> inspect(leaks)
    end
  end

  defp await_terminate_report do
    assert_receive {:ns17p_log, %{msg: {:report, %{label: {:gen_statem, :terminate}} = r}}},
                   @report_timeout_ms,
                   "F1-R3 control: no gen_statem terminate report reached the handler"

    r
  end

  # Token-shaped canary built at run time; the source never holds the joined
  # prefix, so no line of this file matches the anthropic_token pattern.
  defp canary do
    prefix = Enum.join(["s", "k-ant-"])
    prefix <> "ns17p" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
  end

  defp control_marker, do: "ns17p_ctl_" <> Integer.to_string(System.unique_integer([:positive]))

  defp render(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  defp hit?(haystack, canary) do
    upper = Base.encode16(canary)
    lower = Base.encode16(canary, case: :lower)
    Enum.any?([canary, Base.encode64(canary), upper, lower], &String.contains?(haystack, &1))
  end

  defp wait_until(fun, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @wait_timeout_ms

    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(@poll_interval_ms)
        wait_until(fun, deadline)
    end
  end
end
