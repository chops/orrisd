defmodule AiPair.Test.PaneSupervisorBudget do
  @moduledoc """
  Test-only pacing for rows that deliberately kill a child of the real, VM-global
  `AiPair.PaneSupervisor` (quarantine_test's transient-restart rows, s3a_release_red_test R6/R8).

  WHY. Every such kill spends one restart of that supervisor's intensity. `AiPair.PaneSupervisor`
  sets neither `:max_restarts` nor `:max_seconds`, so the pinned Elixir defaults apply (3 restarts
  per 5 s, counted in WHOLE seconds: `add_restart` stamps `:erlang.monotonic_time(1)`). A 4th
  restart inside the window shuts the supervisor down; `AiPair.Supervisor` restarts it EMPTY and no
  replacement pane ever registers. A per-module stamp list (quarantine_test's former helper) cannot
  see kills made by other modules in the same VM, and the hosted run of 2026-10-07 (Orrisd
  37587819648 attempt 2) failed exactly that way.

  WHAT. `await!/1` reads the supervisor's OWN restart list (`:sys.get_state/1`, the
  `DynamicSupervisor` state's `:restarts`, `:max_restarts`, `:max_seconds`) and waits until fewer
  than `max_restarts` stamps are live, a stamp counting as live one whole second longer than the
  supervisor itself counts it (`now <= then + max_seconds + 1`). It is bounded: it raises when the
  supervisor is not running, when its state lacks those fields, or when no slot opens before the
  deadline, rather than killing into an exhausted budget.

  LIMIT. This reads private `DynamicSupervisor` state; a state shape change fails loudly here. The
  rows that use it are `async: false`, so no concurrent test can spend the slot between the check
  and the kill.
  """

  @supervisor AiPair.PaneSupervisor
  @margin_s 1
  @poll_ms 50

  @spec await!(pos_integer()) :: :ok
  def await!(timeout_ms \\ 8_000) do
    do_await!(System.monotonic_time(:millisecond) + timeout_ms)
  end

  @doc "How many of `restarts` (monotonic whole-second stamps) are live at `now`."
  @spec live_count([integer()], non_neg_integer(), integer()) :: non_neg_integer()
  def live_count(restarts, max_seconds, now),
    do: Enum.count(restarts, &(now <= &1 + max_seconds + @margin_s))

  defp do_await!(deadline) do
    {restarts, max_restarts, max_seconds} = budget!()

    cond do
      live_count(restarts, max_seconds, :erlang.monotonic_time(1)) < max_restarts ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        raise "no #{inspect(@supervisor)} restart slot opened before the deadline"

      true ->
        Process.sleep(@poll_ms)
        do_await!(deadline)
    end
  end

  defp budget! do
    if Process.whereis(@supervisor) == nil do
      raise "#{inspect(@supervisor)} is not running; there is no restart budget to read"
    end

    case :sys.get_state(@supervisor) do
      %{restarts: restarts, max_restarts: max_restarts, max_seconds: max_seconds}
      when is_list(restarts) and is_integer(max_restarts) and max_restarts > 0 ->
        {restarts, max_restarts, max_seconds}

      other ->
        raise "#{inspect(@supervisor)} state has no usable restart budget: #{inspect(other, limit: 5)}"
    end
  end
end
