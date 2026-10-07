defmodule AiPair.Admission.MarkerSource do
  @moduledoc """
  The session_marker dimension of the quiesce observation (NS-32.M.002 RB-3a GREEN-2, design
  r4 W4): one version for the session markers of every committed pane, or `:error` (the quiesce
  then answers observation_incomplete naming session_marker).

  The session set is derived, never configured: the distinct tmux session ids of the panes the
  committed pane-intent records name, from ONE census through the configured adapter (the
  reconciler's own census, `AiPair.Tmux.observe_panes/1`). Each step that cannot certify is
  `:error`, in order:

    1. the intent read fails, or there is no committed record (no attached session to certify);
    2. the census fails; or a committed pane has not EXACTLY ONE census row (absent, or observed
       more than once, in one session or across sessions, whatever the markers say); or its row
       has no session id;
    3. a session's marker read is anything but `{:ok, marker}` (absent, malformed, unavailable,
       a source error, an exit);
    4. the markers of the set disagree on version.

  Sources: `:intent` (the pane-intent store), `:tmux` (the adapter), and optional `:census` and
  `:read_marker` overrides (tests only) standing in for `AiPair.Tmux.observe_panes/1` and
  `AiPair.PaneRestore.Marker.read/2`.
  """

  alias AiPair.PaneIntentStore
  alias AiPair.PaneRestore.Marker

  @spec observe(map()) :: {:ok, pos_integer()} | :error
  def observe(sources) do
    census = Map.get(sources, :census, fn -> AiPair.Tmux.observe_panes(sources.tmux) end)
    read = Map.get(sources, :read_marker, &Marker.read(sources.tmux, &1))

    with {:ok, [_ | _] = records} <- PaneIntentStore.list(sources.intent),
         {:ok, rows} when is_list(rows) <- census.(),
         {:ok, sessions} <- sessions(records, rows),
         {:ok, versions} <- versions(sessions, read),
         [version] <- Enum.uniq(versions) do
      {:ok, version}
    else
      _ -> :error
    end
  catch
    _, _ -> :error
  end

  defp sessions(records, rows) do
    Enum.reduce_while(records, {:ok, MapSet.new()}, fn record, {:ok, acc} ->
      case Enum.filter(rows, &(Map.get(&1, :pane_id) == record["pane_id"])) do
        [%{session_id: session}] when is_binary(session) and session != "" ->
          {:cont, {:ok, MapSet.put(acc, session)}}

        _ ->
          {:halt, :error}
      end
    end)
  end

  defp versions(sessions, read) do
    sessions
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn session, {:ok, acc} ->
      case read.(session) do
        {:ok, %{version: version}} when is_integer(version) -> {:cont, {:ok, [version | acc]}}
        _ -> {:halt, :error}
      end
    end)
  end
end
