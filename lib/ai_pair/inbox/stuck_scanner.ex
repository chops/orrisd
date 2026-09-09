defmodule AiPair.Inbox.StuckScanner do
  @moduledoc """
  Periodic scanner for envelopes that have been sitting in
  `$AI_PAIR_INBOX/inbox/` longer than they should.

  An envelope is "stuck" when:
    1. it has been in `inbox/` for at least `:age_threshold_ms` (file
       mtime, preserved by a same-filesystem rename from `outbox/`), and
    2. the addressed pane is alive and reports `state: :idle` (so the
       peer pane *should* have consumed it but hasn't), OR there is no
       addressed pane id (role-only envelopes still get reported so an
       operator can see the backlog).

  Each stuck envelope emits a `[:ai_pair, :inbox, :stuck]` telemetry
  event with:

      measurements: %{age_s: pos_integer()}
      metadata: %{pane_id: String.t() | nil, msg_id: String.t() | nil,
                  path: String.t()}

  The scanner is read-only — it never moves, edits, or deletes
  envelopes. Cleanup is the consuming pane's responsibility; retention
  of `processed/` is the launchd timer's responsibility.
  """

  use GenServer

  require Logger

  @default_poll_interval_ms 60_000
  @default_age_threshold_ms 300_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = %{
      inbox: Keyword.fetch!(opts, :inbox),
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms),
      age_threshold_ms: Keyword.get(opts, :age_threshold_ms, @default_age_threshold_ms)
    }

    schedule_scan(state.poll_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:scan, state) do
    scan(state)
    schedule_scan(state.poll_interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_scan(interval_ms) do
    Process.send_after(self(), :scan, interval_ms)
  end

  defp scan(%{inbox: inbox, age_threshold_ms: threshold_ms}) do
    inbox_dir = Path.join(inbox, "inbox")
    now = System.system_time(:millisecond)

    case File.ls(inbox_dir) do
      {:ok, entries} ->
        Enum.each(entries, fn name ->
          path = Path.join(inbox_dir, name)

          with true <- String.ends_with?(name, ".json"),
               {:ok, %File.Stat{type: :regular, mtime: mtime}} <- File.stat(path, time: :posix),
               age_ms = now - mtime * 1000,
               true <- age_ms >= threshold_ms,
               true <- pane_idle?(decode_envelope(path)) do
            envelope = decode_envelope(path)

            :telemetry.execute(
              [:ai_pair, :inbox, :stuck],
              %{age_s: div(age_ms, 1000)},
              %{
                pane_id: envelope[:pane_id],
                msg_id: envelope[:msg_id],
                path: path
              }
            )
          end
        end)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("ai-pair stuck-scanner: ls #{inbox_dir} failed: #{inspect(reason)}")
    end
  end

  defp decode_envelope(path) do
    case File.read(path) do
      {:ok, bytes} ->
        case Jason.decode(bytes) do
          {:ok, %{} = json} ->
            %{
              pane_id: get_in(json, ["to", "pane_id"]),
              msg_id: Map.get(json, "msg_id")
            }

          _ ->
            %{pane_id: nil, msg_id: nil}
        end

      _ ->
        %{pane_id: nil, msg_id: nil}
    end
  end

  # Role-only envelopes (no pane_id) always count as stuck once age
  # exceeds threshold — there's no per-pane gate to apply.
  defp pane_idle?(%{pane_id: nil}), do: true

  defp pane_idle?(%{pane_id: pane_id}) when is_binary(pane_id) do
    case AiPair.PaneSupervisor.whereis_pane(pane_id) do
      {:ok, _pid} ->
        try do
          case AiPair.Pane.StateMachine.status(AiPair.PaneSupervisor.via_pane(pane_id)) do
            %{state: :idle} -> true
            _ -> false
          end
        catch
          :exit, _ -> false
        end

      :error ->
        false
    end
  end
end
