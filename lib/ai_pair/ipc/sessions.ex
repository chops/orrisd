defmodule AiPair.IPC.Sessions do
  @moduledoc "Read-only v2 session observations; no receipt or lifecycle operations."

  require OpenTelemetry.Tracer, as: Tracer

  @max_payload 1_048_576
  @request_keys ~w(cmd protocol_version traceparent tracestate)
  @reply_keys ~w(ok protocol_version sessions)
  @session_keys ~w(panes session_id session_name)
  @address_keys ~w(pane_id pane_index registered_at_observation window_index)
  @errors ~w(invalid_sessions_request invalid_sessions_census sessions_unavailable oversize)
  @observation_keys [
    :command,
    :pane_id,
    :pane_index,
    :pane_pid,
    :path,
    :session_id,
    :session_name,
    :window_index
  ]

  def dispatch(params, opts \\ []) do
    Tracer.with_span "ipc.sessions", %{kind: :server, attributes: %{"ipc.protocol_version" => 2}} do
      reply = read_request(params, opts)
      Tracer.set_attribute("ipc.ok", reply["ok"])
      if not reply["ok"], do: Tracer.set_status(:error, reply["error"])
      reply
    end
  end

  # The server sends this result, never the unbounded candidate encoding.
  def encode_reply(reply) do
    encoded = Jason.encode!(reply)

    if byte_size(encoded) > @max_payload,
      do: Jason.encode!(error("oversize")),
      else: encoded
  end

  def project(observations, %MapSet{} = registered) when is_list(observations) do
    if Enum.all?(observations, &valid_observation?/1) do
      groups = Enum.group_by(observations, & &1.session_id)

      if Enum.all?(groups, fn {_id, rows} ->
           rows |> Enum.map(& &1.session_name) |> Enum.uniq() |> length() == 1
         end) do
        sessions =
          groups
          |> Enum.map(fn {id, rows} ->
            panes =
              rows
              |> Enum.map(fn row ->
                %{
                  "pane_id" => row.pane_id,
                  "window_index" => row.window_index,
                  "pane_index" => row.pane_index,
                  "registered_at_observation" => MapSet.member?(registered, row.pane_id)
                }
              end)
              |> Enum.sort_by(&address_key/1)

            %{"session_id" => id, "session_name" => hd(rows).session_name, "panes" => panes}
          end)
          |> Enum.sort_by(& &1["session_id"])

        reply = %{"protocol_version" => 2, "ok" => true, "sessions" => sessions}
        if valid_reply?(reply), do: reply, else: error("invalid_sessions_census")
      else
        error("invalid_sessions_census")
      end
    else
      error("invalid_sessions_census")
    end
  end

  def project(_observations, _registered), do: error("invalid_sessions_census")

  @doc "Validates decoded sessions replies before the CLI can print them."
  def valid_reply?(%{"protocol_version" => 2, "ok" => true, "sessions" => sessions} = reply)
      when is_list(sessions) do
    exact_keys?(reply, @reply_keys) and Enum.all?(sessions, &valid_session?/1) and
      ordered_unique?(Enum.map(sessions, & &1["session_id"])) and consistent_membership?(sessions)
  end

  def valid_reply?(%{"protocol_version" => 2, "ok" => false, "error" => reason} = reply) do
    exact_keys?(reply, ~w(error ok protocol_version)) and reason in @errors
  end

  def valid_reply?(_reply), do: false

  defp read_request(params, opts) do
    if valid_request?(params) do
      observe = Keyword.get(opts, :observe, &observe/0)
      registered = Keyword.get(opts, :registered, &registered_panes/0)

      case safely(observe) do
        {:ok, observations} ->
          case safely(registered) do
            %MapSet{} = panes -> project(observations, panes)
            _ -> error("sessions_unavailable")
          end

        {:error, {:row_arity, _, _, _}} ->
          error("invalid_sessions_census")

        {:error, {:malformed_pid, _}} ->
          error("invalid_sessions_census")

        {:error, {:malformed_index, _, _}} ->
          error("invalid_sessions_census")

        {:error, {:malformed_text, _, _}} ->
          error("invalid_sessions_census")

        _ ->
          error("sessions_unavailable")
      end
    else
      error("invalid_sessions_request")
    end
  end

  defp valid_request?(%{"cmd" => "sessions", "protocol_version" => 2} = params),
    do: Enum.all?(Map.keys(params), &(&1 in @request_keys))

  defp valid_request?(_params), do: false

  defp observe do
    AiPair.Tmux.observe_panes(Application.get_env(:ai_pair, :tmux_server, AiPair.Tmux))
  end

  defp registered_panes do
    Registry.select(AiPair.Registry, [{{{:pane, :"$1"}, :_, :_}, [], [:"$1"]}])
    |> MapSet.new()
  end

  defp safely(fun) do
    fun.()
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp valid_observation?(row) when is_map(row) do
    exact_keys?(row, @observation_keys) and pane_id?(row.pane_id) and session_id?(row.session_id) and
      text?(row.session_name) and index?(row.window_index) and index?(row.pane_index) and
      is_integer(row.pane_pid) and row.pane_pid > 0 and text?(row.command) and text?(row.path)
  end

  defp valid_observation?(_row), do: false

  defp valid_session?(session) when is_map(session) do
    exact_keys?(session, @session_keys) and session_id?(session["session_id"]) and
      text?(session["session_name"]) and is_list(session["panes"]) and
      Enum.all?(session["panes"], &valid_address?/1) and
      ordered_unique?(Enum.map(session["panes"], &address_key/1)) and
      unique?(Enum.map(session["panes"], &{&1["window_index"], &1["pane_index"]}))
  end

  defp valid_session?(_session), do: false

  defp valid_address?(address) when is_map(address) do
    exact_keys?(address, @address_keys) and pane_id?(address["pane_id"]) and
      index?(address["window_index"]) and index?(address["pane_index"]) and
      is_boolean(address["registered_at_observation"])
  end

  defp valid_address?(_address), do: false

  defp consistent_membership?(sessions) do
    sessions
    |> Enum.flat_map(& &1["panes"])
    |> Enum.group_by(& &1["pane_id"], & &1["registered_at_observation"])
    |> Enum.all?(fn {_id, flags} -> length(Enum.uniq(flags)) == 1 end)
  end

  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == keys
  defp ordered_unique?(values), do: values == Enum.sort(values) and unique?(values)
  defp unique?(values), do: values == Enum.uniq(values)
  defp index?(value), do: is_integer(value) and value >= 0
  defp text?(value), do: is_binary(value) and value != "" and String.valid?(value)
  defp pane_id?(value), do: is_binary(value) and Regex.match?(~r/\A%[0-9]+\z/, value)
  defp session_id?(value), do: is_binary(value) and Regex.match?(~r/\A\$[0-9]+\z/, value)

  defp address_key(address),
    do: {address["window_index"], address["pane_index"], address["pane_id"]}

  defp error(reason), do: %{"protocol_version" => 2, "ok" => false, "error" => reason}
end
