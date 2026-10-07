defmodule AiPair.Test.FakeTmuxAdapter do
  @moduledoc """
  An in-BEAM stand-in for the `AiPair.Tmux` adapter, for full-application rows that configure
  it as `:tmux_server` (NS-32.M.002 RB-3a GREEN-2). It answers the adapter's own call messages
  from state the test controls: the census (`:observe_panes`), session options (the session
  marker: `show_options`, `set_option`, `set_option_if_absent`) and captures. Anything else is
  refused with a status-97 error, so a path the row did not script cannot act on a real tmux.

  It is started unlinked (it must outlive the application stops and starts a row performs) and
  stopped by the row's `on_exit`.
  """

  use GenServer

  @refused %{status: 97, stderr: "fake tmux adapter refused", stdout: ""}

  def start!(rows) do
    name = String.to_atom("fake_tmux_adapter_#{System.unique_integer([:positive])}")
    {:ok, pid} = GenServer.start(__MODULE__, rows, name: name)
    ExUnit.Callbacks.on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    name
  end

  @doc "Replace the census rows."
  def put_rows(server, rows), do: GenServer.call(server, {:fake_put_rows, rows})

  @doc "Every option write the adapter received, oldest first."
  def writes(server), do: GenServer.call(server, :fake_writes)

  @impl true
  def init(rows), do: {:ok, %{rows: rows, options: %{}, writes: []}}

  @impl true
  def handle_call({:fake_put_rows, rows}, _from, state), do: {:reply, :ok, %{state | rows: rows}}
  def handle_call(:fake_writes, _from, state), do: {:reply, Enum.reverse(state.writes), state}

  # While a path is watched, every census records whether that path existed when the census
  # was taken: an ordered trace of a census relative to a file (the daemon socket).
  def handle_call({:fake_watch, path}, _from, state),
    do: {:reply, :ok, Map.merge(state, %{watch: path, trace: []})}

  def handle_call(:fake_trace, _from, state),
    do: {:reply, Enum.reverse(Map.get(state, :trace, [])), state}

  def handle_call(:observe_panes, _from, %{watch: path} = state) do
    {:reply, {:ok, state.rows}, %{state | trace: [{:census, File.exists?(path)} | state.trace]}}
  end

  def handle_call(:observe_panes, _from, state), do: {:reply, {:ok, state.rows}, state}

  def handle_call({:show_options, target, option}, _from, state) do
    case Map.fetch(state.options, {target, option}) do
      {:ok, value} ->
        {:reply, {:ok, value <> "\n"}, state}

      :error ->
        {:reply, {:error, %{@refused | status: 1, stderr: "invalid option: #{option}"}}, state}
    end
  end

  def handle_call({:set_option_if_absent, target, option, value}, _from, state) do
    state = %{state | writes: [{target, option, value} | state.writes]}

    if Map.has_key?(state.options, {target, option}),
      do: {:reply, :ok, state},
      else: {:reply, :ok, put_in(state.options[{target, option}], value)}
  end

  def handle_call({:set_option, target, option, value}, _from, state) do
    state = %{state | writes: [{target, option, value} | state.writes]}
    {:reply, :ok, put_in(state.options[{target, option}], value)}
  end

  def handle_call({:fake_put_screen, screen}, _from, state),
    do: {:reply, :ok, Map.put(state, :screen, screen)}

  # Every capture served is counted by pane, so a row can prove a child captures through THIS
  # configured adapter (not the PATH tmux).
  def handle_call({:capture_pane, pane, _opts}, _from, state) do
    captures = Map.update(Map.get(state, :captures, %{}), pane, 1, &(&1 + 1))
    {:reply, {:ok, Map.get(state, :screen, "")}, Map.put(state, :captures, captures)}
  end

  def handle_call(:fake_captures, _from, state), do: {:reply, Map.get(state, :captures, %{}), state}

  # A gated transaction is forwarded to a REAL AiPair.Tmux adapter when the row names one, so
  # tmux.ex do_gated_paste/4 (begin_command, the store-run steps, end_command) runs for real.
  def handle_call({:fake_gated_to, real}, _from, state),
    do: {:reply, :ok, Map.put(state, :gated_to, real)}

  def handle_call(
        {:gated_paste, _pane, _payload, _gate} = request,
        _from,
        %{gated_to: real} = state
      ),
      do: {:reply, GenServer.call(real, request, :infinity), state}

  def handle_call(_other, _from, state), do: {:reply, {:error, @refused}, state}
end
