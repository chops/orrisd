defmodule AiPair.CLI.Consult do
  @moduledoc false

  require OpenTelemetry.Tracer, as: Tracer

  @default_wait_secs 600
  @poll_ms 2_000
  @kind "consultation"
  @msg_id_pattern ~r/^[A-Za-z0-9_-]{16,64}$/
  @known_agents ~w(claude_code codex_cli)
  @agent_to_protocol %{"claude_code" => "claude", "codex_cli" => "codex"}

  @doc false
  def default_wait_secs, do: @default_wait_secs

  @doc false
  def valid_msg_id?(id) when is_binary(id), do: Regex.match?(@msg_id_pattern, id)
  def valid_msg_id?(_), do: false

  @doc false
  def mint_msg_id do
    "m_" <>
      Integer.to_string(:erlang.system_time(:nanosecond)) <>
      "_" <>
      Base.encode16(:rand.bytes(4), case: :lower)
  end

  @doc false
  @spec parse_args([String.t()]) :: {:ok, map()} | :error
  def parse_args(args) when is_list(args) do
    with {:ok, parsed} <- do_parse(args, base_parse_state()),
         {:ok, source} <- parse_source(parsed),
         {:ok, msg_id, minted?} <- parse_msg_id(parsed.msg_id) do
      wait_secs = if parsed.wait?, do: parsed.wait_secs || @default_wait_secs, else: nil

      {:ok,
       %{
         source: source,
         peer: parsed.peer,
         wait?: parsed.wait?,
         wait_secs: wait_secs,
         msg_id: msg_id,
         msg_id_minted?: minted?
       }}
    else
      _ -> :error
    end
  end

  def parse_args(_), do: :error

  @doc false
  @spec run(map(), keyword()) :: 0 | 1
  def run(opts, runtime_opts \\ []) do
    request_fn = Keyword.get(runtime_opts, :request_fn, &AiPair.CLI.Client.request/1)
    tmux_panes_fn = Keyword.get(runtime_opts, :tmux_panes_fn, &tmux_panes/0)
    stdin_fn = Keyword.get(runtime_opts, :stdin_fn, fn -> IO.read(:stdio, :eof) end)
    sleep_fn = Keyword.get(runtime_opts, :sleep_fn, &Process.sleep/1)
    env = Keyword.get(runtime_opts, :env, System.get_env())

    Tracer.with_span "cli.consult", %{
      kind: :client,
      attributes: %{
        "cli.command" => "consult",
        "messaging.message.id" => opts.msg_id
      }
    } do
      exit_code =
        opts
        |> read_body(stdin_fn)
        |> continue_with_body(opts, request_fn, tmux_panes_fn, sleep_fn, env)

      Tracer.set_attribute("cli.exit_code", exit_code)
      exit_code
    end
  end

  defp base_parse_state do
    %{
      body_parts: [],
      peer: nil,
      stdin?: false,
      wait?: false,
      wait_secs: nil,
      msg_id: nil
    }
  end

  defp do_parse([], acc), do: {:ok, %{acc | body_parts: Enum.reverse(acc.body_parts)}}

  defp do_parse(["--" | rest], acc) do
    {:ok, %{acc | body_parts: Enum.reverse(acc.body_parts) ++ rest}}
  end

  defp do_parse(["--stdin" | rest], acc), do: do_parse(rest, %{acc | stdin?: true})

  defp do_parse(["--peer=" <> peer | rest], acc), do: parse_peer(peer, rest, acc)

  defp do_parse(["--peer", peer | rest], acc), do: parse_peer(peer, rest, acc)
  defp do_parse(["--peer"], _acc), do: :error

  defp do_parse(["--msg-id=" <> id | rest], acc), do: do_parse(rest, %{acc | msg_id: id})

  defp do_parse(["--msg-id", id | rest], acc), do: do_parse(rest, %{acc | msg_id: id})
  defp do_parse(["--msg-id"], _acc), do: :error

  defp do_parse(["--wait=" <> raw_secs | rest], acc) do
    case parse_wait_secs(raw_secs) do
      {:ok, secs} -> do_parse(rest, %{acc | wait?: true, wait_secs: secs})
      :error -> :error
    end
  end

  defp do_parse(["--wait" | rest], acc) do
    case consume_optional_wait_secs(rest) do
      {:ok, wait_secs, rest} -> do_parse(rest, %{acc | wait?: true, wait_secs: wait_secs})
      :error -> :error
    end
  end

  defp do_parse(["--" <> _flag | _rest], _acc), do: :error

  defp do_parse([part | rest], acc) when is_binary(part) do
    do_parse(rest, %{acc | body_parts: [part | acc.body_parts]})
  end

  defp parse_peer(peer, rest, acc) when peer in @known_agents do
    do_parse(rest, %{acc | peer: peer})
  end

  defp parse_peer(_peer, _rest, _acc), do: :error

  defp consume_optional_wait_secs([candidate | rest]) do
    case parse_wait_secs(candidate) do
      {:ok, secs} ->
        {:ok, secs, rest}

      :error ->
        if String.match?(candidate, ~r/^-?\d/) do
          :error
        else
          {:ok, @default_wait_secs, [candidate | rest]}
        end
    end
  end

  defp consume_optional_wait_secs([]), do: {:ok, @default_wait_secs, []}

  defp parse_wait_secs(raw) do
    case Integer.parse(raw) do
      {secs, ""} when secs >= 0 -> {:ok, secs}
      _ -> :error
    end
  end

  defp parse_source(%{stdin?: true, body_parts: []}), do: {:ok, :stdin}

  defp parse_source(%{stdin?: false, body_parts: [_ | _] = parts}) do
    {:ok, {:literal, Enum.join(parts, " ")}}
  end

  defp parse_source(_), do: :error

  defp parse_msg_id(nil), do: {:ok, mint_msg_id(), true}

  defp parse_msg_id(id) do
    if valid_msg_id?(id), do: {:ok, id, false}, else: :error
  end

  defp read_body(%{source: {:literal, body}}, _stdin_fn), do: {:ok, body}

  defp read_body(%{source: :stdin}, stdin_fn) do
    case stdin_fn.() do
      :eof -> {:ok, ""}
      {:error, reason} -> {:error, {:stdin_read, reason}}
      body when is_binary(body) -> {:ok, body}
      other -> {:error, {:stdin_read, other}}
    end
  end

  defp continue_with_body({:error, reason}, _opts, _request_fn, _tmux_panes_fn, _sleep_fn, _env) do
    runtime_error(format_error(reason))
  end

  defp continue_with_body({:ok, body}, opts, request_fn, tmux_panes_fn, sleep_fn, env) do
    with {:ok, inbox} <- resolve_inbox(env),
         {:ok, participants} <- resolve_participants(opts.peer, request_fn, tmux_panes_fn, env),
         {:ok, final_path} <- publish_envelope(inbox, opts.msg_id, body, participants, env),
         :ok <- maybe_wake_peer(participants, opts.msg_id, final_path, request_fn) do
      maybe_wait_for_reply(inbox, opts, participants, final_path, sleep_fn)
    else
      {:error, reason} -> runtime_error(format_error(reason))
    end
  end

  defp resolve_inbox(env) do
    case Map.get(env, "AI_PAIR_INBOX") do
      inbox when is_binary(inbox) and inbox != "" -> {:ok, inbox}
      _ -> {:error, :missing_inbox}
    end
  end

  defp resolve_participants(explicit_peer, request_fn, tmux_panes_fn, env) do
    self_pane = nonempty(Map.get(env, "TMUX_PANE"))
    self_status = pane_status(self_pane, request_fn)
    pane_statuses = collect_pane_statuses(tmux_panes_fn, request_fn, self_status)

    self_agent = status_agent(self_status)
    peer_agent = explicit_peer || infer_peer_agent(self_agent, self_pane, pane_statuses)
    self_agent = self_agent || opposite_agent(peer_agent)

    with true <- peer_agent in @known_agents,
         true <- self_agent in @known_agents do
      peer_pane = find_pane_for_agent(peer_agent, self_pane, pane_statuses)

      Tracer.set_attribute("peer.agent", peer_agent)

      if peer_pane do
        Tracer.set_attribute("peer.pane_id", peer_pane)
      end

      {:ok,
       %{
         self_agent: protocol_agent(self_agent),
         self_agent_classifier: self_agent,
         self_pane_id: self_pane,
         peer_agent: protocol_agent(peer_agent),
         peer_agent_classifier: peer_agent,
         peer_pane_id: peer_pane
       }}
    else
      _ -> {:error, :peer_not_inferred}
    end
  end

  defp pane_status(nil, _request_fn), do: nil

  defp pane_status(pane_id, request_fn) do
    case request_fn.(%{"cmd" => "pane_status", "pane_id" => pane_id}) do
      {:ok, %{"ok" => true} = status} -> status
      _ -> nil
    end
  end

  defp collect_pane_statuses(tmux_panes_fn, request_fn, self_status) do
    tmux_panes_fn.()
    |> case do
      {:ok, panes} -> panes
      _ -> []
    end
    |> Enum.map(&pane_status(&1, request_fn))
    |> Enum.reject(&is_nil/1)
    |> prepend_status(self_status)
    |> Enum.uniq_by(&Map.get(&1, "pane_id"))
  end

  defp prepend_status(statuses, nil), do: statuses
  defp prepend_status(statuses, status), do: [status | statuses]

  defp status_agent(%{"agent" => agent}) when agent in @known_agents, do: agent
  defp status_agent(_), do: nil

  defp infer_peer_agent(self_agent, _self_pane, _statuses) when self_agent in @known_agents do
    opposite_agent(self_agent)
  end

  defp infer_peer_agent(nil, self_pane, statuses) when is_binary(self_pane) do
    statuses
    |> Enum.reject(&(Map.get(&1, "pane_id") == self_pane))
    |> Enum.map(&status_agent/1)
    |> Enum.filter(&(&1 in @known_agents))
    |> Enum.uniq()
    |> case do
      [agent] -> agent
      _ -> nil
    end
  end

  defp infer_peer_agent(_self_agent, _self_pane, _statuses), do: nil

  defp opposite_agent("claude_code"), do: "codex_cli"
  defp opposite_agent("codex_cli"), do: "claude_code"
  defp opposite_agent(_), do: nil

  defp protocol_agent(agent), do: Map.fetch!(@agent_to_protocol, agent)

  defp find_pane_for_agent(agent, self_pane, statuses) do
    statuses
    |> Enum.find(fn status ->
      status_agent(status) == agent and Map.get(status, "pane_id") != self_pane
    end)
    |> case do
      nil -> nil
      status -> nonempty(Map.get(status, "pane_id"))
    end
  end

  defp publish_envelope(inbox, msg_id, body, participants, env) do
    outbox_dir = Path.join(inbox, "outbox")
    inbox_dir = Path.join(inbox, "inbox")
    stage_path = Path.join(outbox_dir, "#{msg_id}.json")
    final_path = Path.join(inbox_dir, "#{msg_id}.json")

    envelope = envelope(msg_id, body, participants, env)

    with :ok <- File.mkdir_p(outbox_dir),
         :ok <- File.mkdir_p(inbox_dir),
         :ok <- ensure_absent(stage_path),
         :ok <- ensure_absent(final_path),
         {:ok, json} <- Jason.encode(envelope, pretty: true),
         :ok <- File.write(stage_path, json <> "\n"),
         :ok <- File.rename(stage_path, final_path) do
      {:ok, final_path}
    else
      {:error, reason} ->
        _ = File.rm(stage_path)
        {:error, {:publish_failed, reason}}
    end
  end

  defp ensure_absent(path) do
    if File.exists?(path), do: {:error, {:exists, path}}, else: :ok
  end

  defp envelope(msg_id, body, participants, env) do
    %{
      "schema_version" => "1.0",
      "msg_id" => msg_id,
      "ts" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "from" =>
        drop_nils(%{
          "agent" => participants.self_agent,
          "pane_id" => participants.self_pane_id
        }),
      "to" =>
        drop_nils(%{
          "agent" => participants.peer_agent,
          "pane_id" => participants.peer_pane_id
        }),
      "kind" => @kind,
      "body" => body
    }
    |> maybe_put("headers", trace_headers())
    |> maybe_put("context", context(env))
  end

  defp context(env) do
    drop_nils(%{
      "project" => nonempty(Map.get(env, "AI_PAIR_PROJECT"))
    })
    |> case do
      empty when map_size(empty) == 0 -> nil
      context -> context
    end
  end

  defp trace_headers do
    :otel_propagator_text_map.inject([])
    |> Map.new()
  catch
    _, _ -> %{}
  end

  defp maybe_wake_peer(%{peer_pane_id: nil}, _msg_id, final_path, _request_fn) do
    IO.puts(:stderr, "ai-pair: peer pane unknown; published #{final_path} without wakeup")
    :ok
  end

  defp maybe_wake_peer(%{peer_pane_id: pane_id}, msg_id, final_path, request_fn) do
    text =
      "Peer consultation #{msg_id} staged at #{final_path}. " <>
        "Read it and reply with in_reply_to=#{msg_id}."

    case request_fn.(%{"cmd" => "send", "pane_id" => pane_id, "text" => text, "msg_id" => msg_id}) do
      {:ok, %{"ok" => true}} -> :ok
      {:ok, %{"ok" => false, "error" => error}} -> {:error, {:wakeup_failed, error}}
      {:ok, payload} -> {:error, {:wakeup_failed, payload}}
      {:error, reason} -> {:error, {:wakeup_failed, reason}}
    end
  end

  defp maybe_wait_for_reply(
         inbox,
         %{wait?: true, wait_secs: secs, msg_id: msg_id},
         participants,
         _path,
         sleep_fn
       ) do
    deadline_ms = System.monotonic_time(:millisecond) + secs * 1_000

    case wait_for_reply(
           Path.join(inbox, "inbox"),
           msg_id,
           participants.self_agent,
           deadline_ms,
           sleep_fn
         ) do
      {:ok, body} ->
        IO.puts(body)
        0

      {:error, :timeout} ->
        runtime_error("timed out waiting #{secs}s for reply to #{msg_id}")
    end
  end

  defp maybe_wait_for_reply(_inbox, %{wait?: false, msg_id: msg_id}, participants, path, _sleep_fn) do
    IO.puts(
      Jason.encode!(%{
        ok: true,
        msg_id: msg_id,
        kind: @kind,
        path: path,
        peer_agent: participants.peer_agent
      })
    )

    0
  end

  defp wait_for_reply(inbox_dir, msg_id, self_agent, deadline_ms, sleep_fn) do
    case find_reply(inbox_dir, msg_id, self_agent) do
      {:ok, body} ->
        {:ok, body}

      :not_found ->
        now = System.monotonic_time(:millisecond)

        if now >= deadline_ms do
          {:error, :timeout}
        else
          sleep_fn.(min(@poll_ms, deadline_ms - now))
          wait_for_reply(inbox_dir, msg_id, self_agent, deadline_ms, sleep_fn)
        end
    end
  end

  defp find_reply(inbox_dir, msg_id, self_agent) do
    Path.join(inbox_dir, "*.json")
    |> Path.wildcard()
    |> Enum.find_value(:not_found, fn path ->
      with {:ok, raw} <- File.read(path),
           {:ok, json} <- Jason.decode(raw),
           true <- Map.get(json, "in_reply_to") == msg_id,
           true <- get_in(json, ["to", "agent"]) == self_agent do
        {:ok, Map.get(json, "body", "")}
      else
        _ -> false
      end
    end)
  end

  defp tmux_panes do
    case System.cmd("tmux", ["list-panes", "-F", "\#{pane_id}"], stderr_to_stdout: true) do
      {out, 0} ->
        panes =
          out
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {:ok, panes}

      {out, status} ->
        {:error, {:tmux_list_panes, status, out}}
    end
  rescue
    e -> {:error, {:tmux_list_panes, Exception.message(e)}}
  end

  defp runtime_error(msg) do
    Tracer.set_status(:error, msg)
    IO.puts(:stderr, "ai-pair: " <> msg)
    1
  end

  defp format_error(:missing_inbox), do: "AI_PAIR_INBOX is not set; run inside an ai-pair session"

  defp format_error(:peer_not_inferred),
    do: "could not infer peer; pass --peer claude_code|codex_cli"

  defp format_error({:stdin_read, reason}), do: "failed to read stdin: " <> inspect(reason)
  defp format_error({:publish_failed, {:exists, path}}), do: "envelope already exists at #{path}"

  defp format_error({:publish_failed, reason}),
    do: "failed to publish envelope: " <> inspect(reason)

  defp format_error({:wakeup_failed, reason}), do: "failed to wake peer: " <> inspect(reason)
  defp format_error(other), do: inspect(other)

  defp nonempty(value) when is_binary(value) and value != "", do: value
  defp nonempty(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, empty) when empty == %{}, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp drop_nils(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
