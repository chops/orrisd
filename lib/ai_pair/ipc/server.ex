defmodule AiPair.IPC.Server do
  @moduledoc """
  Unix domain socket server. Listens at `$AI_PAIR_INBOX/sock/ai-pair.sock`.

  ## Access control: there is none against a same-user process

  This is the only IPC surface between the CLI binaries and the daemon. No port,
  no network surface. The whole of its access control is filesystem permissions:
  the parent `sock/` directory is chmod 0700 by `AiPair.Inbox` and the socket
  file is chmod 0600 here immediately after bind.

  Those two modes exclude every OTHER user on the host. They exclude NOTHING
  from a process that already runs as the operator. Stated plainly, because the
  wording this replaces named the mechanism without naming the adversary it
  stops:

  > Any process running as the operator has full daemon authority. It may
  > `attach_pane`, `detach_pane`, ask `pane_status`, and `send` text up to
  > `@max_send_text_bytes` into any live agent pane. The pane is an interactive
  > agent CLI, so a `send` is keystroke injection into a running agent and can
  > make it do anything that agent can do.

  This daemon authenticates no caller. No frame in either protocol version
  carries an actor, an identity, a token or a credential; `AiPair.IPC.Delivery`
  validates the identity of the MESSAGE, never of the caller; and no
  peer-credential check exists anywhere in `lib/`. Nothing here is a
  vulnerability that a later commit forgot to fix — it is the trust model of a
  local-first single-user harness, written down so that no reader mistakes
  "0600" or "no network surface" for protection against a malicious local
  process.

  Two consequences a reader may NOT draw from the modes above: that a second
  agent CLI the operator started for an unrelated task is outside this
  surface, and that a downloaded binary, a package postinstall script or an
  editor extension running as the operator is outside it. All three are inside
  it, with full authority.

  ### What a peer-credential check would need decided first

  Refusing a connecting uid that is not the socket owner's is the obvious
  hardening, and it is NOT taken here, for a reason that is about contracts and
  not about effort. `docs/contracts/ipc-v1.org` opens by recording that the v1
  fixtures are shared byte-for-byte with the Orris consumer and pins the paired
  consumer revision and both `CONTRACT_HASH` files; the same document states
  that a change reaching into both repositories "is a reviewed change in BOTH
  repositories, so a single-repository lane cannot make it". A new admission
  refusal is exactly such a change: it adds an outcome to the surface those
  fixtures describe, on a connection the consumer's `PaneClient` opens.

  So the decision this check waits on is not "should the daemon be safer". It
  is: under which contract revision does the IPC surface acquire a refusal that
  no fixture has, and who authors the matching consumer change. A uid check is
  also weaker than binding an operator identity, so taking it here would not
  settle that question either way.

  The second reason is mechanical and was MEASURED, not assumed, at Elixir
  1.20.4 / OTP 29.0.5 on `{:unix, :darwin}`, against a socket accepted exactly
  the way `accept_loop/3` accepts one:

    * `:inet.getopts(sock, [:peercred])` — and `:peercreds`, and `:peer_cred` —
      answers `{:error, :einval}`. There is no named option.
    * `:socket.is_supported(:options, :socket, :peercred)` answers `false`, so
      OTP's own portable spelling is unavailable on this platform.
    * the Linux spelling, raw `SOL_SOCKET`/`SO_PEERCRED`, answers
      `{:error, :eopnotsupp}` through `:socket`, and `{:ok, []}` through
      `:inet` — an empty list, which is the shape a caller is most likely to
      mistake for a successful read of nothing.
    * only a raw `getsockopt(SOL_LOCAL, LOCAL_PEERCRED)` answers, returning 76
      opaque bytes that a caller must decode as a `struct xucred` to find the
      uid in them.

  A check built on that last line is a platform-specific raw option number plus
  a hand-written C struct layout, with a DIFFERENT option number and a DIFFERENT
  layout on Linux — and `.github/workflows/verify.yml` runs this repository's
  only automated verification on `ubuntu-24.04`. The darwin half would therefore
  be a control no automated run ever exercises, on the platform the operator
  actually develops on, which is the defect class this project treats as its
  worst: a check that cannot fail. Writing that without a ruling on which
  platforms must enforce it, and on what a host that cannot answer at all should
  do, would be building the appearance of a defence rather than a defence.

  Architecture:
    * This GenServer owns the listen socket.
    * A linked acceptor task does blocking `:gen_tcp.accept/1` in a loop.
      When it receives a connection, it transfers ownership of the client
      socket to a temporary handler task and resumes accepting.
    * Handler tasks run under `AiPair.IPC.ConnectionSupervisor`
      (`Task.Supervisor`, restart: :temporary). A crashing handler does
      not touch the acceptor or the listener.
    * That supervisor is capped at `max_concurrent_connections/0` children,
      the bound `AiPair.Application` passes as its `max_children:`. The cap is
      enforced inside the supervisor, so a connection beyond it is REFUSED —
      `Task.Supervisor.start_child/2` answers `{:error, :max_children}`, the
      acceptor closes that client socket and resumes accepting. Nothing is
      queued and nothing waits, which is the difference between a bounded
      surface and one that merely defers the growth.
    * On startup, the server probes the existing socket path with a brief
      connect attempt. If a daemon answers, we refuse to start; if the
      socket is stale (ECONNREFUSED / ENOENT), we unlink and bind.

  Wire protocol: 4-byte big-endian length prefix + UTF-8 JSON payload.
  BEAM-managed framing via `{:packet, 4}` — payloads up to `@max_frame_bytes`
  are accepted; oversize frames close the socket with `:emsgsize`.

  Command dispatch covers `ping`, `attach_pane`, `send`, `pane_status`,
  and `detach_pane` — each wrapped in an OTel span and re-routed to the
  appropriate pane via `AiPair.PaneSupervisor` / `AiPair.Pane.StateMachine`.

  ## Durable attach

  Contract: `docs/contracts/durable-attach-detach.org`. Durability is a
  daemon-wide setting (`Application.get_env(:ai_pair, :durable_attachments) ==
  true`, a literal `true` and nothing else), re-read for every dispatch, while
  the boot generation is fixed once at server start. With the setting unset
  every reply below is byte-for-byte the legacy one and no coordinator, marker
  or store is consulted.

  An `attach_pane` frame carrying `"durable": true` asks for the attachment to
  be RECORDED as well as started. Three rules shape that path.

  A durable request that cannot be honoured is refused BEFORE any effect. The
  metadata gate, the store lookup, the pane fence, the pane observation and the
  marker all run before a state machine is started and before anything is
  written, so a refusal leaves nothing half-done to explain.

  Nothing is invented to satisfy the record schema. A request with no agent is
  refused rather than stored with a sentinel, and the fields describing the pane
  itself are taken from ONE tmux census row or not taken at all — an
  unobservable pane is refused, because a fabricated `pane_pid` is
  indistinguishable to every later reader from one that was measured.

  The first owner's identity wins. When a state machine already runs for the
  pane, the record carries ITS agent and classifier, never the second caller's.

  `persist_outcome` reports what the store said about disk. `persisted` is the
  stronger claim and is emitted only where a commit was observed to complete.

  ## Durable withdrawal

  A `detach_pane` frame carries no durability flag, because withdrawal is not a
  per-request choice: if this daemon records attachments at all, a detach that
  left the record behind would be reasserted at the next boot.

  Three answers are kept apart. A lookup that SUCCEEDED and found no record is
  `"skipped"`. A lookup that could not answer at all — no store owner, or an
  owner that refused the read — is `"uncertain"`, and it may not be spelled
  `pane_not_found`, because reporting a store we could not reach as an
  authoritative absence is exactly the collapse this boundary exists to prevent.

  The record is withdrawn BEFORE the pane child is stopped, mirroring the attach
  order: a withdrawal whose durable half failed leaves no daemon-side effect to
  explain. `repair_required` means the requested effect did not take effect and
  nothing retries it.
  """

  use GenServer

  alias AiPair.IPC.Delivery
  alias AiPair.IPC.Sessions
  alias AiPair.PaneRestore.Coordinator
  alias AiPair.PaneRestore.Marker

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  @sock_subpath "sock/ai-pair.sock"
  @handler_recv_timeout_ms 5_000
  @probe_timeout_ms 100
  @max_frame_bytes 1_048_576
  @max_send_text_bytes 524_288
  @default_send_call_timeout_ms 5_000

  # Cap on concurrently live connection handlers, passed by `AiPair.Application`
  # as the `max_children:` of `AiPair.IPC.ConnectionSupervisor`. Without it the
  # supervisor accepts handlers without bound, and a local process that opens
  # sockets in a loop and sends nothing holds one handler and one socket each
  # for `@handler_recv_timeout_ms`, growing until the VM runs out of ports or
  # processes.
  #
  # The value is NOT a new number. `@max_pending_sends` in
  # `AiPair.Pane.StateMachine` is this repository's only other count bound, and
  # this one is deliberately the same literal, set the same way: a module
  # attribute on the module that owns the bounded surface, read everywhere else
  # through an accessor so the number exists in one place, and reported to the
  # caller rather than defaulted away. Taking a different figure would be
  # inventing one, and nothing measured here justifies a second convention.
  #
  # What the figure has to clear is one command per connection: `ap` and the
  # Orris `PaneClient` both open a socket, send one frame, read one reply and
  # close. Thirty-two of those outstanding AT ONCE is far above any observed
  # operator or orchestrator burst, and a handler that has been answered is
  # gone, so the cap bites on connections that are open and idle, which is what
  # T-22 of the MCP threat model describes.
  @max_concurrent_connections 32

  @doc """
  The concurrent connection-handler cap, as `AiPair.Application` applies it.

  Read this rather than the literal: the cap lives here, beside the frame and
  payload bounds of the same surface, and the supervision child spec calls it.
  """
  @spec max_concurrent_connections() :: pos_integer()
  def max_concurrent_connections, do: @max_concurrent_connections

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    if Delivery.available?(Keyword.get(opts, :receipt_store)) do
      # The generation is validated HERE so a bad one raises in the caller
      # rather than being reported as an opaque init failure, and it is fixed
      # once: a later flip of `:durable_attachments` cannot manufacture one.
      GenServer.start_link(__MODULE__, {opts, server_context!(opts)}, name: name)
    else
      {:error, :receipt_store_unavailable}
    end
  end

  @impl true
  def init({opts, context}) do
    Process.flag(:trap_exit, true)
    inbox = Keyword.fetch!(opts, :inbox)
    sock_path = Path.join(inbox, @sock_subpath)

    with :ok <- ensure_no_live_daemon(sock_path),
         :ok <- unlink_stale(sock_path),
         {:ok, listen_socket} <- :gen_tcp.listen(0, listen_opts(sock_path)),
         :ok <- File.chmod(sock_path, 0o600),
         {:ok, acceptor} <- start_acceptor(listen_socket, context) do
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

  defp start_acceptor(listen_socket, context) do
    parent = self()
    pid = :proc_lib.spawn_link(fn -> accept_loop(parent, listen_socket, context) end)
    {:ok, pid}
  end

  defp accept_loop(parent, listen, context) do
    case :gen_tcp.accept(listen) do
      {:ok, client} ->
        case spawn_handler(client, context) do
          {:ok, _handler_pid} -> :ok
          {:error, _reason} -> :gen_tcp.close(client)
        end

        accept_loop(parent, listen, context)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit({:accept_failed, reason})
    end
  end

  defp spawn_handler(client, context) do
    case Task.Supervisor.start_child(AiPair.IPC.ConnectionSupervisor, fn ->
           receive do
             :go -> handle_connection(client, context)
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

  defp handle_connection(client, context) do
    case :gen_tcp.recv(client, 0, @handler_recv_timeout_ms) do
      {:ok, frame} ->
        :gen_tcp.send(client, handle_frame(frame, context))
        :gen_tcp.close(client)

      {:error, _reason} ->
        :gen_tcp.close(client)
    end
  end

  defp handle_frame(frame, context) do
    case Jason.decode(frame) do
      {:ok, decoded} ->
        # Pull any W3C traceparent/tracestate the CLI injected so each
        # `ipc.*` span links back to the originating `cli.*` span. Extract
        # both attaches the remote ctx AND returns the previous token to
        # detach in `after` — leaking would poison subsequent dispatches.
        token = extract_remote_ctx(decoded)

        try do
          dispatch_version(decoded, context)
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

  defp dispatch_version(params, %{receipt_store: store} = context) when is_map(params) do
    case Map.get(params, "protocol_version", 1) do
      1 ->
        do_dispatch(params |> Map.put(:receipt_store, store) |> Map.put(:durable_context, context))

      2 ->
        if params["cmd"] == "sessions" do
          params |> Sessions.dispatch() |> Sessions.encode_reply()
        else
          Jason.encode!(Delivery.dispatch(params, store))
        end

      _ ->
        Jason.encode!(Delivery.unsupported(params))
    end
  end

  defp dispatch_version(other, _context), do: do_dispatch(other)

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
      result = dispatch_attach(params, pane_id, agent)
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

  defp do_dispatch(%{"cmd" => "detach_pane", "pane_id" => pane_id} = params)
       when is_binary(pane_id) and pane_id != "" do
    Tracer.with_span "ipc.detach_pane", %{
      kind: :server,
      attributes: drop_nils(%{"pane.id" => pane_id})
    } do
      result = detach_pane(pane_id, Map.fetch!(params, :durable_context))
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

  defp attach_pane(pane_id, agent, store, fenced \\ false)

  defp attach_pane(pane_id, agent, store, fenced) when agent == nil or is_binary(agent) do
    resolved = resolve_classifier(agent)
    start_opts = build_start_opts(agent, resolved) |> Keyword.put(:receipt_store, store)

    case start_registered_pane(pane_id, start_opts, fenced) do
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

  defp attach_pane(pane_id, _agent, _store, _fenced) do
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

  defp detach_pane(pane_id, context) do
    cond do
      not durable_enabled?() -> legacy_detach(pane_id)
      context.boot_generation == nil -> unavailable_detach(pane_id)
      true -> lifecycle_transaction(pane_id, fn -> durable_detach(pane_id) end)
    end
  end

  defp unavailable_detach(pane_id) do
    %{
      ok: false,
      pane_id: pane_id,
      error: "durable_unavailable",
      persist_outcome: "uncertain",
      repair_required: true
    }
  end

  defp legacy_detach(pane_id) do
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

  # ------------------------------------------------------------------ durable

  # Mode is read for each dispatch, while the trusted boot generation is fixed.
  # Disabling mode restores ordinary legacy behaviour on this same IPC server.
  defp dispatch_attach(params, pane_id, agent) do
    context = Map.fetch!(params, :durable_context)
    explicit_durable = Map.get(params, "durable") == true

    cond do
      not durable_enabled?() ->
        if explicit_durable,
          do: disabled_durable_attach(pane_id, agent),
          else: attach_pane(pane_id, agent, context.receipt_store)

      context.boot_generation == nil ->
        unavailable_attach(pane_id, agent, explicit_durable)

      true ->
        lifecycle_transaction(pane_id, fn ->
          if explicit_durable,
            do: durable_attach_enabled(pane_id, agent, context),
            else: attach_pane(pane_id, agent, context.receipt_store, true)
        end)
    end
  end

  defp durable_enabled?, do: Application.get_env(:ai_pair, :durable_attachments) == true

  # A server started in legacy mode never captured a durable generation. Later
  # enabling the feature cannot manufacture one, even from a new env override.
  # Explicit durable requests still receive their metadata errors first.
  defp unavailable_attach(pane_id, agent, true) do
    case durable_missing(agent, configured_binding()) do
      [] ->
        unavailable_attach(pane_id, agent, false)

      missing ->
        %{ok: false, pane_id: pane_id, error: "durable_metadata_missing", missing: missing}
    end
  end

  defp unavailable_attach(pane_id, _agent, false),
    do: %{ok: false, pane_id: pane_id, error: "durable_unavailable"}

  # Preserve metadata validation and the store lookup in disabled mode. A store
  # that happens to exist is not enrolment in durable lifecycle ownership.
  # Neither outcome may consult Coordinator or mutate a marker, record or pane.
  defp disabled_durable_attach(pane_id, agent) do
    binding = configured_binding()

    case durable_missing(agent, binding) do
      [] ->
        case durable_store(binding.project_inbox) do
          :error -> unavailable_attach(pane_id, agent, false)
          {:ok, _store} -> unavailable_attach(pane_id, agent, false)
        end

      missing ->
        %{ok: false, pane_id: pane_id, error: "durable_metadata_missing", missing: missing}
    end
  end

  # A binding that is not the exact three-field map is no binding. It is read as
  # absent rather than partially adopted, so the missing fields are NAMED to the
  # caller instead of being filled in from whatever happened to be configured.
  defp configured_binding do
    case Application.get_env(:ai_pair, :project_binding) do
      %{project: project, project_dir: dir, project_inbox: inbox} ->
        %{project: project, project_dir: dir, project_inbox: inbox}

      _other ->
        %{project: nil, project_dir: nil, project_inbox: nil}
    end
  end

  # Every missing field is reported, not just the first one found: a caller
  # repairing its request needs the whole list. "agent" appears whenever the
  # request carried none, because the alternative — storing "unknown" in the one
  # field whose entire purpose is an identity hint — is a lie the store would
  # then make permanent.
  defp durable_missing(agent, binding) do
    checks = [
      {"agent", durable_text?(agent)},
      {"project", durable_text?(binding.project)},
      {"project_dir", durable_path?(binding.project_dir)},
      {"project_inbox", durable_path?(binding.project_inbox)}
    ]

    for {field, false} <- checks, do: field
  end

  defp durable_text?(value), do: is_binary(value) and value != "" and String.valid?(value)

  defp durable_path?(value), do: durable_text?(value) and Path.type(value) == :absolute

  # The store owner registers itself globally under its canonical root
  # (`pane_intent_store.ex`, `claim_then_start/3`). No owner is not an empty
  # store: it is no store at all, and the request is refused before a pane is
  # started rather than started and then reported as unrecorded.
  defp durable_store(root) do
    case :global.whereis_name({AiPair.PaneIntentStore, Path.expand(root)}) do
      :undefined -> :error
      pid -> {:ok, pid}
    end
  end

  # FIRST OWNER WINS. A running state machine is the identity the daemon
  # actually holds, and `attach_pane/4` already reports it on a duplicate
  # attach. Recording the second caller's agent instead would overwrite a fact
  # with a claim no process ever carried, which defeats the reason the record is
  # on disk at all.
  defp durable_owner(pane_id, agent) do
    case AiPair.PaneSupervisor.whereis_pane(pane_id) do
      {:ok, pid} ->
        info = pane_info(pid)
        %{agent: info.agent, classifier: info.classifier_name || "stub"}

      :error ->
        %{agent: agent, classifier: durable_classifier(resolve_classifier(agent))}
    end
  end

  defp durable_classifier({:ok, _classifier_fn, name}), do: name
  defp durable_classifier({:fallback, _reason}), do: "stub"

  defp census(adapter) do
    case AiPair.Tmux.observe_panes(adapter) do
      {:ok, observations} -> {:ok, observations}
      {:error, _reason} -> :error
    end
  catch
    # A stopped or unresponsive adapter means the query could not be made, which
    # is not evidence about the pane either way.
    :exit, _reason -> :error
  end

  # The pane facts come from ONE census row and nowhere else. There is no
  # per-field fallback, because a record mixing measured and guessed fields is
  # indistinguishable downstream from one that was wholly measured.
  defp durable_record(pane_id, owner, binding, observation, generation) do
    %{
      "schema_version" => AiPair.PaneIntentStore.Record.version(),
      "pane_id" => pane_id,
      "agent" => owner.agent,
      "classifier" => owner.classifier,
      "project" => binding.project,
      "project_dir" => binding.project_dir,
      "project_inbox" => binding.project_inbox,
      "tmux_session" => observation.session_name,
      "session_gen" => generation,
      "cwd" => observation.path,
      "command" => observation.command,
      "pane_pid" => observation.pane_pid,
      "updated_at" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  # -------------------------------------------------------- durable withdrawal

  # Only a literal `true` records attachments, so only the daemon-wide setting
  # withdraws them. There is no `durable` key on a detach frame.
  defp durable_detach(pane_id) do
    case durable_detach_store() do
      {:ok, store} ->
        withdraw_intent(pane_id, store)

      :error ->
        # NOT `pane_not_found`. No owner is not an empty store; it is no store at
        # all, and nothing may be claimed about disk in either direction.
        %{
          ok: false,
          pane_id: pane_id,
          error: "durable_unavailable",
          persist_outcome: "uncertain",
          repair_required: true
        }
    end
  end

  # A binding we cannot read gives us no root to look under, which is the same
  # inability as a missing owner and is reported the same way — never as an
  # absence we did not measure.
  defp durable_detach_store do
    inbox = configured_binding().project_inbox

    if durable_path?(inbox), do: durable_store(inbox), else: :error
  end

  # The two refusals below differ in what was MEASURED, not in how they ended.
  # `skipped` is an answer: the store was read and holds no such record, so
  # nothing was attempted and nothing needs repair. `uncertain` is the absence of
  # an answer. Collapsing them would report a store we never read as proof the
  # pane was never recorded.
  defp withdraw_intent(pane_id, store) do
    case recorded_intent(store, pane_id) do
      {:ok, true} ->
        remove_intent(pane_id, store)

      {:ok, false} ->
        %{
          ok: false,
          pane_id: pane_id,
          error: "pane_not_found",
          persist_outcome: "skipped"
        }

      :unknown ->
        %{
          ok: false,
          pane_id: pane_id,
          error: "durable_lookup_failed",
          persist_outcome: "uncertain",
          repair_required: true
        }
    end
  end

  # A read that FAILED is not a read that found nothing. A poisoned owner and a
  # call that exits both leave the record's existence unknown, and an unknown is
  # propagated as one rather than defaulted to either side.
  defp recorded_intent(store, pane_id) do
    case AiPair.PaneIntentStore.list(store) do
      {:ok, records} -> {:ok, Enum.any?(records, &(&1["pane_id"] == pane_id))}
      {:error, _reason} -> :unknown
    end
  catch
    :exit, {:timeout, _} -> throw({:store_timeout, :list})
    :exit, _reason -> :unknown
  end

  # ORDER IS THE CONTRACT, as it is on attach. The record goes first and the pane
  # child is stopped only after the store confirmed the commit, so a withdrawal
  # whose durable half failed leaves no daemon-side effect behind to explain.
  #
  # `persisted` is emitted only here, where a commit was observed to complete.
  # Both failure outcomes carry `persist_outcome` alone and say repair is
  # required: the operator asked for a withdrawal that did not happen, and
  # nothing retries it.
  defp remove_intent(pane_id, store) do
    case delete_intent(store, pane_id) do
      :ok ->
        %{
          ok: true,
          pane_id: pane_id,
          status: "intent_withdrawn",
          pane_registered: stop_registered_pane(pane_id),
          persisted: true,
          persist_outcome: "committed"
        }

      {:error, outcome, stage} ->
        %{
          ok: false,
          pane_id: pane_id,
          persist_stage: stage,
          error: "durable_withdrawal_failed",
          status: "withdrawal_failed",
          persist_outcome: outcome,
          repair_required: true
        }
    end
  end

  # A call that exits is an UNKNOWN result, never an unchanged one: the owner may
  # have committed and then died.
  defp delete_intent(store, pane_id) do
    case AiPair.PaneIntentStore.delete(store, pane_id) do
      :ok ->
        :ok

      {:error, %{outcome: outcome, stage: stage}} ->
        {:error, Atom.to_string(outcome), Atom.to_string(stage)}
    end
  catch
    :exit, {:timeout, _} -> throw({:store_timeout, :delete})
    :exit, _reason -> {:error, "uncertain", "delete"}
  end

  # Reports whether a daemon pane CHILD was registered for this pane and has
  # therefore been stopped. It describes the child only — a tmux pane is not
  # killed by a detach — and a record withdrawn with no running child is the
  # ordinary post-restart shape, not an error.
  defp stop_registered_pane(pane_id) do
    case AiPair.PaneSupervisor.whereis_pane(pane_id) do
      :error ->
        false

      {:ok, pid} ->
        case Coordinator.submit(pane_id, AiPair.PaneSupervisor, {:terminate_child, pid}, :infinity) do
          {:ok, :ok} -> true
          {:ok, {:error, :not_found}} -> false
          {:error, reason} -> throw({:lifecycle_stop_failed, reason})
        end
    end
  end

  # ------------------------------------------------------------- the mode gate

  defp server_context!(opts) do
    durable = durable_enabled?()
    # `get`, not `fetch!`: an absent option is the same caller defect as a
    # malformed one and is reported as one ArgumentError, not as a KeyError.
    generation = if durable, do: Keyword.get(opts, :boot_generation), else: nil

    if durable and not (is_binary(generation) and Regex.match?(~r/\A[0-9]+\z/, generation)) do
      raise ArgumentError, "boot_generation must be a nonempty ASCII decimal string"
    end

    %{
      receipt_store: Keyword.fetch!(opts, :receipt_store),
      boot_generation: generation
    }
  end

  # In durable mode EVERY mutating pane-lifecycle frame goes through the fence,
  # legacy-shaped frames included: the fence is per pane, not per feature.
  defp lifecycle_transaction(pane, fun) do
    result =
      Coordinator.transaction(pane, fn ->
        try do
          {:ok, fun.()}
        catch
          :throw, {:store_timeout, stage} ->
            {:unresolved, {:store_timeout, stage}}

          :throw, {:lifecycle_stop_failed, reason} ->
            {:ok,
             %{
               ok: false,
               pane_id: pane,
               error: "coordinator_unavailable",
               coordinator_error: inspect(reason),
               repair_required: true,
               persist_outcome: "committed"
             }}
        end
      end)

    case result do
      {:ok, reply} ->
        reply

      {:unresolved, cause} ->
        unresolved_reply(pane, cause)

      {:error, reason} ->
        %{ok: false, pane_id: pane, error: Atom.to_string(reason)}

      {:fence_update_failed, body, reason} ->
        reply =
          case body do
            {:ok, reply} -> reply
            {:unresolved, cause} -> unresolved_reply(pane, cause)
          end

        # OQ-1 of the contract: `body_error` is emitted even when the body
        # SUCCEEDED, where it is `nil` and encodes as JSON `null`. That is the
        # shape `attach.error.fence_update_failed.json` pins, so it is what this
        # producer emits; the contradiction with the contract's
        # absence-is-the-discriminator rule is recorded, not silently resolved.
        reply
        |> Map.delete(:persisted)
        |> Map.put(:ok, false)
        |> Map.put(:body_error, Map.get(reply, :error))
        |> Map.put(:error, "coordinator_unavailable")
        |> Map.put(:coordinator_error, inspect(reason))
        |> Map.put(:repair_required, true)
    end
  end

  defp unresolved_reply(pane, {:store_timeout, stage}) do
    %{
      ok: false,
      pane_id: pane,
      error: "durable_store_timeout",
      repair_required: true,
      persist_outcome: "uncertain",
      persist_stage: Atom.to_string(stage)
    }
  end

  defp start_registered_pane(pane, opts, fenced) do
    # A fenced caller already holds the shared Coordinator transaction, whose
    # public submit API pins and reuses that holder's admitting incarnation.
    if fenced do
      sm_opts = [pane_id: pane, name: AiPair.PaneSupervisor.via_pane(pane)] ++ opts

      spec =
        {{AiPair.Pane.StateMachine, :start_link, [sm_opts]}, :transient, 5_000, :worker,
         [AiPair.Pane.StateMachine]}

      case Coordinator.submit(pane, AiPair.PaneSupervisor, {:start_child, spec}, :infinity) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    else
      AiPair.PaneSupervisor.start_pane(pane, opts)
    end
  end

  defp durable_attach_enabled(pane, agent, context) do
    binding = configured_binding()

    case durable_missing(agent, binding) do
      [] ->
        case durable_store(binding.project_inbox) do
          {:ok, store} -> durable_commit_enabled(pane, agent, binding, store, context)
          :error -> %{ok: false, pane_id: pane, error: "durable_unavailable"}
        end

      missing ->
        %{ok: false, pane_id: pane, error: "durable_metadata_missing", missing: missing}
    end
  end

  defp durable_commit_enabled(pane, agent, binding, store, context) do
    owner = durable_owner(pane, agent)
    tmux = Application.get_env(:ai_pair, :tmux_server, AiPair.Tmux)

    with {:ok, observed} <- observe_unique_pane(pane, tmux),
         :ok <-
           Marker.ensure(tmux, observed.session_id,
             owner_root: binding.project_inbox,
             generation: context.boot_generation
           ),
         {:ok, marker} <- Marker.read(tmux, observed.session_id),
         :ok <- validate_attach_marker(marker, observed, binding),
         {:ok, fresh} <- observe_unique_pane(pane, tmux),
         :ok <- unchanged_attach_source(observed, fresh),
         {:ok, fresh_marker} <- Marker.read(tmux, fresh.session_id),
         :ok <- unchanged_attach_marker(marker, fresh_marker) do
      reply = attach_pane(pane, agent, context.receipt_store, true)

      if reply.ok do
        record = durable_record(pane, owner, binding, fresh, fresh_marker.generation)

        case persist_enabled(store, record) do
          :ok ->
            Map.merge(reply, %{persisted: true, persist_outcome: "committed"})

          {:error, outcome, stage} ->
            %{
              ok: false,
              pane_id: pane,
              error: "durable_write_failed",
              persist_outcome: outcome,
              persist_stage: stage,
              repair_required: true
            }
        end
      else
        reply
      end
    else
      {:error, :observation, error} -> %{ok: false, pane_id: pane, error: error}
      {:error, marker_error} -> marker_refusal(pane, marker_error)
    end
  end

  defp observe_unique_pane(pane, tmux) do
    case census(tmux) do
      {:ok, rows} ->
        case Enum.filter(rows, &(&1.pane_id == pane)) do
          [observation] -> {:ok, observation}
          [] -> {:error, :observation, "durable_pane_unobserved"}
          _ambiguous -> {:error, :observation, "durable_observation_ambiguous"}
        end

      :error ->
        {:error, :observation, "durable_observation_unavailable"}
    end
  end

  defp validate_attach_marker(marker, observation, binding) do
    cond do
      marker.owner_root != binding.project_inbox -> {:error, {:marker_foreign, marker.owner_root}}
      marker.session_id != observation.session_id -> {:error, {:session_mismatch}}
      true -> :ok
    end
  end

  defp unchanged_attach_source(same, same), do: :ok

  defp unchanged_attach_source(_fresh, _snapshot),
    do: {:error, :observation, "durable_observation_changed"}

  defp unchanged_attach_marker(same, same), do: :ok
  defp unchanged_attach_marker(_fresh, _snapshot), do: {:error, {:marker_changed}}

  defp marker_refusal(pane, finding) do
    error =
      case finding do
        {:source_error, :marker, _reason} -> "marker_unavailable"
        {:source_unavailable, :marker} -> "marker_unavailable"
        {:marker_foreign, _root} -> "marker_foreign"
        {:marker_absent} -> "marker_absent"
        {:marker_malformed, _raw} -> "marker_malformed"
        {:session_mismatch} -> "session_mismatch"
        {:marker_changed} -> "marker_changed"
      end

    reply = %{ok: false, pane_id: pane, error: error}

    if error == "marker_unavailable",
      do: Map.put(reply, :persist_outcome, "uncertain"),
      else: reply
  end

  defp persist_enabled(store, record) do
    case AiPair.PaneIntentStore.put(store, record) do
      :ok ->
        :ok

      {:error, %{outcome: outcome, stage: stage}} ->
        {:error, Atom.to_string(outcome), Atom.to_string(stage)}
    end
  catch
    :exit, {:timeout, _} -> throw({:store_timeout, :put})
    :exit, _reason -> {:error, "uncertain", "put"}
  end
end
