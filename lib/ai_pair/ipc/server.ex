defmodule AiPair.IPC.Server do
  @moduledoc """
  Unix domain socket server. Listens at `$AI_PAIR_INBOX/sock/ai-pair.sock`.

  This is the only IPC surface between the CLI binaries and the daemon.
  No port, no network surface — access control is filesystem permissions
  on the parent `sock/` directory (chmod 0700 by `AiPair.Inbox`).

  Architecture:
    * This GenServer owns the listen socket.
    * A linked acceptor task does blocking `:gen_tcp.accept/1` in a loop.
      When it receives a connection, it transfers ownership of the client
      socket to a temporary handler task and resumes accepting.
    * Handler tasks run under `AiPair.IPC.ConnectionSupervisor`
      (`Task.Supervisor`, restart: :temporary). A crashing handler does
      not touch the acceptor or the listener.
    * On startup, the server probes the existing socket path with a brief
      connect attempt. If a daemon answers, we refuse to start; if the
      socket is stale (ECONNREFUSED / ENOENT), we unlink and bind.

  Wire protocol: 4-byte big-endian length prefix + UTF-8 JSON payload.
  BEAM-managed framing via `{:packet, 4}` — payloads up to `@max_frame_bytes`
  are accepted; oversize frames close the socket with `:emsgsize`.

  Command dispatch covers `ping`, `attach_pane`, `send`, `pane_status`,
  and `detach_pane` — each wrapped in an OTel span and re-routed to the
  appropriate pane via `AiPair.PaneSupervisor` / `AiPair.Pane.StateMachine`.
  """

  use GenServer

  alias AiPair.IPC.Delivery

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  @sock_subpath "sock/ai-pair.sock"
  @handler_recv_timeout_ms 5_000
  @probe_timeout_ms 100
  @max_frame_bytes 1_048_576
  @max_send_text_bytes 524_288
  @default_send_call_timeout_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    if Delivery.available?(Keyword.get(opts, :receipt_store)),
      do: GenServer.start_link(__MODULE__, opts, name: name),
      else: {:error, :receipt_store_unavailable}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    inbox = Keyword.fetch!(opts, :inbox)
    sock_path = Path.join(inbox, @sock_subpath)

    with :ok <- ensure_no_live_daemon(sock_path),
         :ok <- unlink_stale(sock_path),
         {:ok, listen_socket} <- :gen_tcp.listen(0, listen_opts(sock_path)),
         :ok <- File.chmod(sock_path, 0o600),
         {:ok, acceptor} <- start_acceptor(listen_socket, Keyword.fetch!(opts, :receipt_store)) do
      Logger.info("ai-pair IPC listening at #{sock_path}")
      {:ok, %{listen: listen_socket, sock_path: sock_path, acceptor: acceptor}}
    else
      {:error, :already_running} -> {:stop, {:already_running, sock_path}}
      {:error, reason} -> {:stop, {:listen_failed, sock_path, reason}}
    end
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{acceptor: pid} = state) do
    {:stop, {:acceptor_exit, reason}, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{listen: listen, sock_path: sock_path}) do
    _ = :gen_tcp.close(listen)
    _ = File.rm(sock_path)
    :ok
  end

  defp listen_opts(sock_path) do
    [
      :binary,
      {:ifaddr, {:local, sock_path}},
      {:active, false},
      {:packet, 4},
      {:packet_size, @max_frame_bytes},
      {:reuseaddr, true}
    ]
  end

  defp ensure_no_live_daemon(sock_path) do
    if File.exists?(sock_path) do
      case :gen_tcp.connect({:local, sock_path}, 0, [:binary, {:active, false}], @probe_timeout_ms) do
        {:ok, port} ->
          :gen_tcp.close(port)
          {:error, :already_running}

        {:error, _reason} ->
          :ok
      end
    else
      :ok
    end
  end

  defp unlink_stale(sock_path) do
    case File.rm(sock_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:unlink_failed, reason}}
    end
  end

  defp start_acceptor(listen_socket, store) do
    parent = self()
    pid = :proc_lib.spawn_link(fn -> accept_loop(parent, listen_socket, store) end)
    {:ok, pid}
  end

  defp accept_loop(parent, listen, store) do
    case :gen_tcp.accept(listen) do
      {:ok, client} ->
        case spawn_handler(client, store) do
          {:ok, _handler_pid} -> :ok
          {:error, _reason} -> :gen_tcp.close(client)
        end

        accept_loop(parent, listen, store)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit({:accept_failed, reason})
    end
  end

  defp spawn_handler(client, store) do
    case Task.Supervisor.start_child(AiPair.IPC.ConnectionSupervisor, fn ->
           receive do
             :go -> handle_connection(client, store)
           after
             @handler_recv_timeout_ms -> :gen_tcp.close(client)
           end
         end) do
      {:ok, pid} ->
        case :gen_tcp.controlling_process(client, pid) do
          :ok ->
            send(pid, :go)
            {:ok, pid}

          {:error, reason} ->
            Process.exit(pid, :kill)
            {:error, reason}
        end

      other ->
        other
    end
  end

  defp handle_connection(client, store) do
    case :gen_tcp.recv(client, 0, @handler_recv_timeout_ms) do
      {:ok, frame} ->
        :gen_tcp.send(client, handle_frame(frame, store))
        :gen_tcp.close(client)

      {:error, _reason} ->
        :gen_tcp.close(client)
    end
  end

  defp handle_frame(frame, store) do
    case Jason.decode(frame) do
      {:ok, decoded} ->
        # Pull any W3C traceparent/tracestate the CLI injected so each
        # `ipc.*` span links back to the originating `cli.*` span. Extract
        # both attaches the remote ctx AND returns the previous token to
        # detach in `after` — leaking would poison subsequent dispatches.
        token = extract_remote_ctx(decoded)

        try do
          dispatch_version(decoded, store)
        after
          if token, do: :otel_ctx.detach(token)
        end

      {:error, _} ->
        Tracer.with_span "ipc.invalid_json", %{kind: :server} do
          Tracer.set_status(:error, "invalid json")
          Jason.encode!(%{ok: false, error: "invalid json"})
        end
    end
  end

  defp extract_remote_ctx(decoded) when is_map(decoded) do
    carrier =
      for key <- ["traceparent", "tracestate"],
          v = Map.get(decoded, key),
          is_binary(v),
          do: {key, v}

    case carrier do
      [] -> nil
      pairs -> :otel_propagator_text_map.extract(pairs)
    end
  end

  defp extract_remote_ctx(_), do: nil

  defp dispatch_version(params, store) when is_map(params) do
    case Map.get(params, "protocol_version", 1) do
      1 -> do_dispatch(Map.put(params, :receipt_store, store))
      2 -> Jason.encode!(Delivery.dispatch(params, store))
      _ -> Jason.encode!(Delivery.unsupported(params))
    end
  end

  defp dispatch_version(other, _store), do: do_dispatch(other)

  defp do_dispatch(%{"cmd" => "ping"}) do
    Tracer.with_span "ipc.ping", %{kind: :server} do
      Jason.encode!(%{ok: true, pong: AiPair.version()})
    end
  end

  defp do_dispatch(%{"cmd" => "attach_pane", "pane_id" => pane_id} = params)
       when is_binary(pane_id) and pane_id != "" do
    agent = Map.get(params, "agent")

    Tracer.with_span "ipc.attach_pane", %{
      kind: :server,
      attributes: drop_nils(%{"pane.id" => pane_id, "pane.agent" => agent})
    } do
      result = attach_pane(pane_id, agent, Map.fetch!(params, :receipt_store))
      annotate_outcome(result)
      Tracer.set_attributes(drop_nils(attach_attrs(result)))
      Jason.encode!(result)
    end
  end

  defp do_dispatch(%{"cmd" => "attach_pane"}) do
    Tracer.with_span "ipc.attach_pane", %{kind: :server} do
      Tracer.set_status(:error, "missing pane_id")
      Jason.encode!(%{ok: false, error: "missing pane_id"})
    end
  end

  defp do_dispatch(%{"cmd" => "send"} = params) do
    Tracer.with_span "ipc.send", %{
      kind: :server,
      attributes: send_input_attrs(params)
    } do
      result = send_to_pane(params)
      annotate_outcome(result)
      Tracer.set_attributes(drop_nils(send_output_attrs(result)))
      Jason.encode!(result)
    end
  end

  defp do_dispatch(%{"cmd" => "pane_status", "pane_id" => pane_id})
       when is_binary(pane_id) and pane_id != "" do
    Tracer.with_span "ipc.pane_status", %{
      kind: :server,
      attributes: drop_nils(%{"pane.id" => pane_id})
    } do
      result = pane_status(pane_id)
      annotate_outcome(result)
      Tracer.set_attributes(drop_nils(pane_status_attrs(result)))
      Jason.encode!(result)
    end
  end

  defp do_dispatch(%{"cmd" => "pane_status"}) do
    Tracer.with_span "ipc.pane_status", %{kind: :server} do
      Tracer.set_status(:error, "missing pane_id")
      Jason.encode!(%{ok: false, error: "missing pane_id"})
    end
  end

  defp do_dispatch(%{"cmd" => "detach_pane", "pane_id" => pane_id})
       when is_binary(pane_id) and pane_id != "" do
    Tracer.with_span "ipc.detach_pane", %{
      kind: :server,
      attributes: drop_nils(%{"pane.id" => pane_id})
    } do
      result = detach_pane(pane_id)
      annotate_outcome(result)
      Tracer.set_attributes(drop_nils(detach_attrs(result)))
      Jason.encode!(result)
    end
  end

  defp do_dispatch(%{"cmd" => "detach_pane"}) do
    Tracer.with_span "ipc.detach_pane", %{kind: :server} do
      Tracer.set_status(:error, "missing pane_id")
      Jason.encode!(%{ok: false, error: "missing pane_id"})
    end
  end

  defp do_dispatch(_other) do
    Tracer.with_span "ipc.unknown", %{kind: :server} do
      Tracer.set_status(:error, "unknown command")
      Jason.encode!(%{ok: false, error: "unknown command"})
    end
  end

  defp annotate_outcome(%{ok: true}), do: :ok

  defp annotate_outcome(%{ok: false} = result) do
    Tracer.set_status(:error, Map.get(result, :error, "") |> to_string())
  end

  defp send_input_attrs(params) do
    drop_nils(%{
      "pane.id" => Map.get(params, "pane_id"),
      "send.bytes" => byte_size_or_nil(Map.get(params, "text")),
      "messaging.message.id" => msg_id_or_nil(Map.get(params, "msg_id"))
    })
  end

  defp msg_id_or_nil(id) when is_binary(id) and id != "", do: id
  defp msg_id_or_nil(_), do: nil

  defp byte_size_or_nil(text) when is_binary(text), do: byte_size(text)
  defp byte_size_or_nil(_), do: nil

  defp attach_attrs(%{ok: true} = r) do
    %{
      "pane.started" => Map.get(r, :started),
      "pane.state" => Map.get(r, :state),
      "pane.classifier" => Map.get(r, :classifier),
      "pane.fallback" => Map.get(r, :fallback)
    }
  end

  defp attach_attrs(%{ok: false} = r) do
    %{"ipc.error" => Map.get(r, :error)}
  end

  defp send_output_attrs(%{ok: true} = r) do
    %{
      "send.status" => Map.get(r, :status),
      "send.queue_reason" => Map.get(r, :queue_reason)
    }
  end

  defp send_output_attrs(%{ok: false} = r) do
    %{
      "ipc.error" => Map.get(r, :error),
      "ipc.error_detail" => Map.get(r, :detail)
    }
  end

  defp pane_status_attrs(%{ok: true} = r) do
    %{
      "pane.state" => Map.get(r, :state),
      "pane.pending_count" => Map.get(r, :pending_count),
      "pane.classifier" => Map.get(r, :classifier)
    }
  end

  defp pane_status_attrs(%{ok: false} = r) do
    %{"ipc.error" => Map.get(r, :error)}
  end

  defp detach_attrs(%{ok: true} = r) do
    %{"detach.status" => Map.get(r, :status)}
  end

  defp detach_attrs(%{ok: false} = r) do
    %{"ipc.error" => Map.get(r, :error)}
  end

  defp drop_nils(map) do
    map
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp attach_pane(pane_id, agent, store) when agent == nil or is_binary(agent) do
    resolved = resolve_classifier(agent)
    start_opts = build_start_opts(agent, resolved) |> Keyword.put(:receipt_store, store)

    case AiPair.PaneSupervisor.start_pane(pane_id, start_opts) do
      {:ok, pid} ->
        reply(pane_id, true, pane_state(pid), agent, resolved)

      {:error, {:already_started, pid}} ->
        info = pane_info(pid)

        %{
          ok: true,
          pane_id: pane_id,
          started: false,
          state: Atom.to_string(info.state),
          agent: info.agent,
          classifier: info.classifier_name || "stub"
        }

      {:error, reason} ->
        %{ok: false, pane_id: pane_id, error: inspect(reason)}
    end
  end

  defp attach_pane(pane_id, _agent, _store) do
    %{ok: false, pane_id: pane_id, error: "agent must be a string"}
  end

  defp send_to_pane(params) do
    pane_id = Map.get(params, "pane_id")
    text = Map.get(params, "text")
    msg_id = msg_id_or_nil(Map.get(params, "msg_id"))

    cond do
      not (is_binary(pane_id) and pane_id != "") ->
        %{ok: false, error: "missing pane_id"}

      not is_binary(text) ->
        %{ok: false, error: "missing text"}

      byte_size(text) > @max_send_text_bytes ->
        %{
          ok: false,
          pane_id: pane_id,
          error: "oversize",
          detail: "text exceeds #{@max_send_text_bytes} bytes"
        }

      true ->
        dispatch_send(pane_id, text, msg_id)
    end
  end

  defp dispatch_send(pane_id, text, msg_id) do
    case AiPair.PaneSupervisor.whereis_pane(pane_id) do
      :error ->
        %{ok: false, pane_id: pane_id, error: "pane_not_found"}

      {:ok, pid} ->
        format_send_result(pane_id, send_via(pid, text, msg_id))
    end
  end

  defp send_via(pid, text, msg_id) do
    timeout =
      Application.get_env(:ai_pair, :send_call_timeout_ms, @default_send_call_timeout_ms)

    try do
      AiPair.Pane.StateMachine.send_legacy(pid, text, timeout, msg_id)
    catch
      # `:gen_statem.call/3` exits with `{:timeout, {:gen_statem, :call, _}}`
      # when the SM does not reply in time. Distinguish this from process
      # death so a slow paste isn't misreported as a dead pane.
      :exit, {:timeout, _} -> {:error, :send_timeout}
      :exit, _ -> {:error, :pane_dead}
    end
  end

  defp format_send_result(pane_id, :ok) do
    %{ok: true, pane_id: pane_id, status: "sent"}
  end

  defp format_send_result(pane_id, {:queued, reason}) when is_atom(reason) do
    %{
      ok: true,
      pane_id: pane_id,
      status: "queued",
      queue_reason: Atom.to_string(reason)
    }
  end

  defp format_send_result(pane_id, {:error, :pane_dead}) do
    %{ok: false, pane_id: pane_id, error: "pane_dead"}
  end

  defp format_send_result(pane_id, {:error, :send_timeout}) do
    %{
      ok: false,
      pane_id: pane_id,
      error: "send_timeout",
      detail: "state machine did not reply within the configured timeout"
    }
  end

  defp format_send_result(pane_id, {:error, {:paste_failed, reason}}) do
    %{
      ok: false,
      pane_id: pane_id,
      error: "paste_failed",
      detail: inspect(reason)
    }
  end

  defp format_send_result(pane_id, {:error, {:queue_full, cap}}) do
    %{
      ok: false,
      pane_id: pane_id,
      error: "queue_full",
      detail: "pending queue at cap=#{cap}"
    }
  end

  defp resolve_classifier(nil), do: :stub_default

  defp resolve_classifier(agent) when is_binary(agent) do
    case AiPair.Pane.Classifier.Loader.load_for_agent(agent) do
      {:ok, classifier_fn, name} ->
        {:ok, classifier_fn, name}

      {:fallback, reason} ->
        Logger.warning("ai-pair: classifier fallback for agent=#{agent}: #{inspect(reason)}")
        {:fallback, reason}
    end
  end

  defp build_start_opts(nil, :stub_default), do: []

  defp build_start_opts(agent, {:ok, classifier_fn, name}) do
    [agent: agent, classifier: classifier_fn, classifier_name: name]
  end

  defp build_start_opts(agent, {:fallback, _reason}) do
    [agent: agent]
  end

  defp reply(pane_id, started, state, nil, :stub_default) do
    %{
      ok: true,
      pane_id: pane_id,
      started: started,
      state: state,
      agent: nil,
      classifier: "stub"
    }
  end

  defp reply(pane_id, started, state, agent, {:ok, _fn, name}) do
    %{
      ok: true,
      pane_id: pane_id,
      started: started,
      state: state,
      agent: agent,
      classifier: name
    }
  end

  defp reply(pane_id, started, state, agent, {:fallback, reason}) do
    %{
      ok: true,
      pane_id: pane_id,
      started: started,
      state: state,
      agent: agent,
      classifier: "stub",
      fallback: format_fallback(reason)
    }
  end

  defp format_fallback(:unknown_agent), do: "unknown_agent"
  defp format_fallback(:priv_dir_unavailable), do: "priv_dir_unavailable"
  defp format_fallback({:load_failed, reason}), do: "load_failed:#{inspect(reason)}"
  defp format_fallback(other), do: inspect(other)

  defp pane_state(pid) do
    try do
      pid |> AiPair.Pane.StateMachine.state() |> Atom.to_string()
    catch
      :exit, _ -> "unknown"
    end
  end

  defp pane_status(pane_id) do
    case AiPair.PaneSupervisor.whereis_pane(pane_id) do
      :error ->
        %{ok: false, pane_id: pane_id, error: "pane_not_found"}

      {:ok, pid} ->
        case pane_status_snapshot(pid) do
          {:ok, snap} ->
            %{
              ok: true,
              pane_id: pane_id,
              state: Atom.to_string(snap.state),
              pending_count: snap.pending_count,
              agent: snap.agent,
              classifier: snap.classifier_name || "stub"
            }

          :error ->
            %{ok: false, pane_id: pane_id, error: "pane_dead"}
        end
    end
  end

  defp pane_status_snapshot(pid) do
    try do
      {:ok, AiPair.Pane.StateMachine.status(pid)}
    catch
      :exit, _ -> :error
    end
  end

  defp detach_pane(pane_id) do
    case AiPair.PaneSupervisor.whereis_pane(pane_id) do
      :error ->
        %{ok: false, pane_id: pane_id, error: "pane_not_found"}

      {:ok, _pid} ->
        case AiPair.PaneSupervisor.stop_pane(pane_id) do
          :ok ->
            %{ok: true, pane_id: pane_id, status: "detached"}

          {:error, :not_found} ->
            # Race: pane vanished between whereis and terminate_child
            # (e.g. SM crashed under us, or another detach raced).
            %{ok: true, pane_id: pane_id, status: "already_detached"}
        end
    end
  end

  defp pane_info(pid) do
    try do
      AiPair.Pane.StateMachine.get_info(pid)
    catch
      :exit, _ -> %{agent: nil, classifier_name: nil, state: :unknown}
    end
  end
end
