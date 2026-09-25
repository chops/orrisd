defmodule AiPair.CLI.Client do
  @moduledoc """
  Unix-domain-socket client for the ai-pair daemon.

  Connects to the daemon's well-known socket at
  `$HOME/.ai-agent-inbox/ai-pair/sock/ai-pair.sock` using `{:packet, 4}`
  framing and JSON payloads, sends a single command, prints the reply
  to stdout, and returns a POSIX-style exit code.

  Socket resolution intentionally does NOT consult `$AI_PAIR_INBOX`:
  inside a project shell that variable points at the per-project inbox,
  not the daemon's listen path. Use `$AI_PAIR_DAEMON_SOCK` (a full path
  to the .sock file) only for tests / out-of-tree daemons.

  Runtime entry point — has no Mix dependency, so it can be invoked
  from a release wrapper (`bin/ai-pair`) via `release eval`. Argv is
  passed through `AI_PAIR_ARGV_B64` (NUL-delimited, base64-encoded)
  because `release eval CODE` does not populate `System.argv/0`.

  Dispatches `ping`, `attach`, `send`, `consult`, `pane_status`, and
  `detach` against the daemon's IPC surface in `AiPair.IPC.Server`.
  The full command surface is documented in `usage/0` below.
  """

  require OpenTelemetry.Tracer, as: Tracer

  alias AiPair.Delivery.ReceiptLog

  @sock_subpath "sock/ai-pair.sock"
  @connect_timeout_ms 2_000
  @recv_timeout_ms 5_000
  @max_frame_bytes 1_048_576
  @trace_carrier_keys ~w(traceparent tracestate)

  @doc """
  Release-wrapper entry. Decodes argv from `AI_PAIR_ARGV_B64`,
  runs the CLI, and halts the BEAM with the resulting exit code.
  """
  @spec main_from_env() :: no_return()
  def main_from_env do
    ensure_otel_started_for_eval()

    exit_code = main(argv())

    # With the eval-local `:simple` processor, ended CLI spans have
    # already been exported before `main/1` returns. Keep the provider
    # flush for custom/already-started SDK configurations.
    try do
      :otel_tracer_provider.force_flush()
    catch
      _, _ -> :ok
    end

    System.halt(exit_code)
  end

  @doc false
  @spec ensure_otel_started_for_eval() :: :ok
  def ensure_otel_started_for_eval do
    # `release eval CODE` runs in an attached node that does NOT start
    # the applications listed in `<release>.rel` — only the bare OTP
    # apps boot. Without this, every `Tracer.with_span` here is a no-op
    # because the OTel SDK isn't running.
    #
    # The release default stays `:batch` for the daemon, but that is not
    # safe for this short-lived eval VM: the Erlang batch processor's
    # `force_flush/1` is an async cast, so `System.halt/1` can kill the
    # VM before the exporter sends the queued span. Override the same
    # `span_processor` key from config/config.exs before OTel starts so
    # span end blocks on OTLP export.
    Application.put_env(:opentelemetry, :span_processor, :simple)
    _ = Application.ensure_all_started(:opentelemetry_exporter)
    _ = Application.ensure_all_started(:opentelemetry)

    :ok
  end

  @doc """
  Run the CLI with an explicit argv. Returns an integer exit code.
  """
  @spec main([String.t()]) :: 0 | 1 | 2
  def main([]), do: ping()
  def main(["ping"]), do: ping()

  def main([verb | rest]) when verb in ["ping", "reconcile"],
    do: run_versioned(verb, parse_versioned(verb, rest))

  def main(["sessions" | rest]) do
    case parse_sessions(rest) do
      :ok -> sessions()
      :error -> cli_error_span("sessions", "sessions accepts only --protocol-version 2")
    end
  end

  def main(["attach" | rest]) do
    case parse_attach(rest) do
      {:ok, pane_id, agent} ->
        attach(pane_id, agent)

      :error ->
        cli_error_span(
          "attach",
          "attach requires a single pane_id argument and an optional --agent <name>"
        )
    end
  end

  def main(["send" | rest]) do
    case parse_versioned("send", rest) do
      :legacy -> legacy_send(rest)
      result -> run_versioned("send", result)
    end
  end

  def main(["consult" | rest]) do
    case parse_consult(rest) do
      {:ok, opts} ->
        AiPair.CLI.Consult.run(opts)

      :error ->
        cli_error_span(
          "consult",
          "consult requires text arguments or --stdin"
        )
    end
  end

  def main(["pane_status" | rest]) do
    case parse_pane_status(rest) do
      {:ok, pane_id} ->
        pane_status(pane_id)

      :error ->
        cli_error_span("pane_status", "pane_status requires a single pane_id argument")
    end
  end

  def main(["detach" | rest]) do
    case parse_detach(rest) do
      {:ok, pane_id} ->
        detach(pane_id)

      :error ->
        cli_error_span("detach", "detach requires a single pane_id argument")
    end
  end

  def main(["help"]), do: cli_help_span()
  def main(["--help"]), do: cli_help_span()
  def main(["-h"]), do: cli_help_span()

  def main(argv) do
    Tracer.with_span "cli.unknown", %{
      kind: :client,
      attributes: %{"cli.command" => "unknown"}
    } do
      Tracer.set_status(:error, "unknown command")
      Tracer.set_attribute("cli.exit_code", 2)
      Tracer.set_attribute("cli.parse_error", true)
      IO.puts(:stderr, "ai-pair: unknown command: " <> Enum.join(argv, " "))
      print_usage(:stderr)
      2
    end
  end

  # Parse-error path. Span kind matches the success path (`:client`) so a
  # trace search by command name returns both. `cli.parse_error=true` is
  # the discriminator for filtering out user-error noise from real
  # daemon-side failures.
  defp legacy_send(rest) do
    case parse_send(rest) do
      {:ok, pane_id, source, msg_id, minted?} ->
        case read_send_text(source) do
          {:ok, text} -> send_text(pane_id, text, msg_id, minted?)
          {:error, reason} -> cli_stdin_error_span(reason, msg_id, minted?)
        end

      :error ->
        cli_error_span("send", "send requires a pane_id and either a text argument or --stdin")
    end
  end

  defp run_versioned(verb, {:ok, payload, :none}), do: run_cmd(verb, payload)

  defp run_versioned("send", {:ok, payload, source}) do
    case read_send_text(source) do
      {:ok, text} ->
        run_cmd("send", Map.put(payload, "text", text), %{
          "messaging.message.id" => payload["msg_id"]
        })

      {:error, _} ->
        cli_stdin_error_span("could not read versioned send input", payload["msg_id"], false)
    end
  end

  defp run_versioned(verb, _), do: cli_error_span(verb, "invalid versioned delivery arguments")

  defp parse_sessions(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [protocol_version: [:integer, :keep]])

    if positional == [] and invalid == [] and
         opts in [[], [protocol_version: 2]],
       do: :ok,
       else: :error
  rescue
    _ -> :error
  end

  defp sessions do
    Tracer.with_span "cli.sessions", %{kind: :client, attributes: %{"cli.command" => "sessions"}} do
      exit_code =
        case request(%{"cmd" => "ping", "protocol_version" => 2}) do
          {:ok, ping} ->
            if sessions_capable?(ping),
              do: read_sessions(),
              else: sessions_error("sessions unavailable: capability preflight failed")

          {:error, _reason} ->
            sessions_error("sessions unavailable: capability preflight failed")
        end

      Tracer.set_attribute("cli.exit_code", exit_code)
      exit_code
    end
  end

  defp sessions_capable?(%{"protocol_version" => 2, "ok" => true, "capabilities" => capabilities})
       when is_list(capabilities) do
    Enum.all?(capabilities, &is_binary/1) and "sessions_read" in capabilities
  end

  defp sessions_capable?(_), do: false

  defp read_sessions do
    case request(%{"cmd" => "sessions", "protocol_version" => 2}) do
      {:ok, reply} ->
        if AiPair.IPC.Sessions.valid_reply?(reply) do
          IO.puts(Jason.encode!(reply))

          if reply["ok"] do
            0
          else
            Tracer.set_status(:error, "daemon returned ok:false")
            1
          end
        else
          sessions_error("protocol_error: invalid sessions reply")
        end

      {:error, _reason} ->
        sessions_error("sessions unavailable: daemon request failed")
    end
  end

  defp sessions_error(message) do
    Tracer.set_status(:error, message)
    IO.puts(:stderr, "ai-pair: " <> message)
    1
  end

  @doc false
  def parse_versioned(verb, args) do
    strict =
      case verb do
        "ping" ->
          [protocol_version: :integer]

        "send" ->
          [protocol_version: :integer, msg_id: :string, stdin: :boolean]

        "reconcile" ->
          [protocol_version: :integer, msg_id: :string, payload_hash: :string, wait_ms: :integer]
      end

    strict = Enum.map(strict, fn {key, type} -> {key, [type, :keep]} end)
    {opts, positional, invalid} = OptionParser.parse(args, strict: strict)
    keys = Keyword.keys(opts)

    cond do
      verb == "send" and not Keyword.has_key?(opts, :protocol_version) -> :legacy
      invalid != [] or keys != Enum.uniq(keys) -> :error
      opts[:protocol_version] != 2 -> :error
      true -> versioned_arguments(verb, positional, opts)
    end
  rescue
    _ -> :error
  end

  defp versioned_arguments("ping", [], _opts),
    do: {:ok, %{"cmd" => "ping", "protocol_version" => 2}, :none}

  defp versioned_arguments("send", positional, opts) do
    source =
      case {Keyword.get(opts, :stdin, false), positional} do
        {true, [pane]} -> {pane, :stdin}
        {false, [pane, text]} -> {pane, {:literal, text}}
        _ -> :error
      end

    with {pane, input} <- source,
         true <- ReceiptLog.valid_pane?(pane) and ReceiptLog.valid_id?(opts[:msg_id]) do
      {:ok,
       %{"cmd" => "send", "protocol_version" => 2, "pane_id" => pane, "msg_id" => opts[:msg_id]},
       input}
    else
      _ -> :error
    end
  end

  defp versioned_arguments("reconcile", [pane], opts) do
    wait = Keyword.get(opts, :wait_ms, 250)

    if ReceiptLog.valid_pane?(pane) and ReceiptLog.valid_id?(opts[:msg_id]) and
         ReceiptLog.valid_hash?(opts[:payload_hash]) and is_integer(wait) and wait >= 0 and
         wait <= 2_000 do
      {:ok,
       %{
         "cmd" => "reconcile",
         "protocol_version" => 2,
         "pane_id" => pane,
         "msg_id" => opts[:msg_id],
         "payload_hash" => opts[:payload_hash],
         "wait_ms" => wait
       }, :none}
    else
      :error
    end
  end

  defp versioned_arguments(_, _, _), do: :error

  defp cli_error_span(name, msg) do
    Tracer.with_span "cli.#{name}", %{
      kind: :client,
      attributes: %{"cli.command" => name}
    } do
      Tracer.set_status(:error, msg)
      Tracer.set_attribute("cli.exit_code", 2)
      Tracer.set_attribute("cli.parse_error", true)
      IO.puts(:stderr, "ai-pair: " <> msg)
      print_usage(:stderr)
      2
    end
  end

  defp cli_help_span do
    Tracer.with_span "cli.help", %{
      kind: :client,
      attributes: %{"cli.command" => "help"}
    } do
      print_usage(:stdio)
      Tracer.set_attribute("cli.exit_code", 0)
      0
    end
  end

  # Distinct from parse errors: argv parsed cleanly but stdin read
  # failed. Exit code 1 (runtime error), no `cli.parse_error` attr.
  # `reason` is already `{:stdin_read, raw}` from read_send_text/1.
  defp cli_stdin_error_span(reason, msg_id, msg_id_minted?) do
    msg = format_error(reason)

    Tracer.with_span "cli.send", %{
      kind: :client,
      attributes:
        %{"cli.command" => "send", "messaging.message.id" => msg_id}
        |> maybe_put("messaging.message.id_minted", minted_attr(msg_id_minted?))
    } do
      Tracer.set_status(:error, msg)
      Tracer.set_attribute("cli.exit_code", 1)
      Tracer.set_attribute("cli.stdin_error", true)
      IO.puts(:stderr, "ai-pair: " <> msg)
      1
    end
  end

  @doc """
  Send a JSON command and return the decoded reply.

  Returns `{:ok, payload}` for any reply (including
  `{:ok, %{"ok" => false, ...}}` from the server). Returns
  `{:error, reason}` for transport-level failures.
  """
  @spec request(map()) :: {:ok, map()} | {:error, term()}
  def request(cmd) when is_map(cmd) do
    sock = sock_path()

    with :ok <- ensure_socket_exists(sock),
         {:ok, conn} <- connect(sock) do
      try do
        # Inject W3C traceparent (and tracestate, if any) into the JSON
        # envelope so the daemon's `ipc.*` span links back to our current
        # `cli.*` span. `:otel_propagator_text_map.inject/1` returns a
        # tuple-list `[{binary, binary}]` — `Map.new/1` flattens it so it
        # JSON-encodes as top-level string keys. Outside an active span
        # the carrier comes back empty and `Map.merge/2` is a no-op.
        #
        # Only `traceparent` and `tracestate` are forwarded: they are the
        # only keys the daemon reads. Any other key a configured propagator
        # emits is dropped, and the command is merged last so its keys
        # always win over the carrier's.
        carrier =
          :otel_propagator_text_map.inject([])
          |> Map.new()
          |> Map.take(@trace_carrier_keys)

        cmd_with_trace = Map.merge(carrier, cmd)

        with :ok <- :gen_tcp.send(conn, Jason.encode!(cmd_with_trace)),
             {:ok, frame} <- :gen_tcp.recv(conn, 0, @recv_timeout_ms) do
          case Jason.decode(frame) do
            {:ok, decoded} -> {:ok, decoded}
            {:error, reason} -> {:error, {:invalid_json, reason}}
          end
        end
      after
        :gen_tcp.close(conn)
      end
    end
  end

  @doc """
  Resolve the daemon socket path.

  Resolution order:

    1. `AI_PAIR_DAEMON_SOCK` — full path to the `.sock` file. Tests and
       out-of-tree daemons set this; the home-manager/launchd modules do
       not.
    2. `$HOME/.ai-agent-inbox/ai-pair/sock/ai-pair.sock` — the daemon's
       well-known listen path under the user's home.

  `$AI_PAIR_INBOX` is intentionally **not** consulted: inside a project
  shell it points at the per-project inbox, not the daemon's listen
  path, so reading it would route the client at the wrong socket.
  """
  @spec sock_path() :: String.t()
  def sock_path do
    case System.get_env("AI_PAIR_DAEMON_SOCK") do
      sock when is_binary(sock) and sock != "" ->
        sock

      _ ->
        Path.join([System.user_home!(), ".ai-agent-inbox/ai-pair", @sock_subpath])
    end
  end

  @doc """
  Decode argv from `AI_PAIR_ARGV_B64`. Public for tests.
  """
  @spec argv() :: [String.t()]
  def argv do
    case System.get_env("AI_PAIR_ARGV_B64") do
      nil -> []
      "" -> []
      b64 -> decode_argv(b64)
    end
  end

  defp decode_argv(b64) do
    case Base.decode64(b64) do
      {:ok, raw} -> split_argv(raw)
      :error -> []
    end
  end

  # `printf '%s\0' "$@"` always emits a trailing NUL, so splitting on
  # `<<0>>` produces a trailing "" element to drop. Empty argv elements
  # in the *middle* are preserved (so `printf '%s\0' "" foo` round-trips
  # to `["", "foo"]`). If the trailing NUL is somehow missing, leave the
  # last element alone rather than silently truncating a real argument.
  defp split_argv(""), do: []

  defp split_argv(raw) do
    parts = :binary.split(raw, <<0>>, [:global])

    case List.last(parts) do
      "" -> Enum.drop(parts, -1)
      _ -> parts
    end
  end

  defp ping, do: run_cmd("ping", %{"cmd" => "ping"})

  # One span per CLI invocation. Kind `:client` because the daemon-side
  # `ipc.*` is the `:server` peer, linked via injected traceparent in
  # `request/1`. The span wraps stdout/stderr printing so latency
  # accounting includes the JSON encode/decode and the kernel write.
  defp run_cmd(name, cmd_payload, extra_attrs \\ %{}) do
    Tracer.with_span "cli.#{name}", %{
      kind: :client,
      attributes: Map.merge(%{"cli.command" => name}, extra_attrs)
    } do
      exit_code =
        case bind_versioned_reply(request(cmd_payload), cmd_payload) do
          {:ok, %{"ok" => true} = payload} ->
            IO.puts(Jason.encode!(payload))
            0

          {:ok, payload} ->
            IO.puts(Jason.encode!(payload))
            Tracer.set_status(:error, "daemon returned ok:false")
            1

          {:error, reason} ->
            msg = format_error(reason)
            IO.puts(:stderr, "ai-pair: " <> msg)
            Tracer.set_status(:error, msg)
            1
        end

      Tracer.set_attribute("cli.exit_code", exit_code)
      exit_code
    end
  end

  defp bind_versioned_reply({:ok, reply}, %{"protocol_version" => 2} = request) do
    if is_map(reply) and reply["protocol_version"] === 2 and is_boolean(reply["ok"]) and
         reply_identity_matches?(reply, request) do
      {:ok, reply}
    else
      {:error, :protocol_reply_mismatch}
    end
  end

  defp bind_versioned_reply(result, _request), do: result

  defp reply_identity_matches?(reply, %{"cmd" => command} = request)
       when command in ["send", "reconcile"] do
    reply["msg_id"] === request["msg_id"] and reply["pane_id"] === request["pane_id"]
  end

  defp reply_identity_matches?(_reply, _request), do: true

  @doc false
  @spec parse_attach([String.t()]) :: {:ok, String.t(), String.t() | nil} | :error
  def parse_attach(args) do
    try do
      {opts, positional, invalid} =
        OptionParser.parse(args, strict: [agent: :string])

      case {invalid, positional} do
        {[], [pane_id]} when is_binary(pane_id) and pane_id != "" ->
          {:ok, pane_id, Keyword.get(opts, :agent)}

        _ ->
          :error
      end
    rescue
      _ -> :error
    end
  end

  @doc false
  @spec parse_pane_status([String.t()]) :: {:ok, String.t()} | :error
  def parse_pane_status(args) do
    try do
      {_opts, positional, invalid} = OptionParser.parse(args, strict: [])

      case {invalid, positional} do
        {[], [pane_id]} when is_binary(pane_id) and pane_id != "" -> {:ok, pane_id}
        _ -> :error
      end
    rescue
      _ -> :error
    end
  end

  @doc false
  @spec parse_detach([String.t()]) :: {:ok, String.t()} | :error
  def parse_detach(args) do
    try do
      {_opts, positional, invalid} = OptionParser.parse(args, strict: [])

      case {invalid, positional} do
        {[], [pane_id]} when is_binary(pane_id) and pane_id != "" -> {:ok, pane_id}
        _ -> :error
      end
    rescue
      _ -> :error
    end
  end

  @doc false
  @spec parse_send([String.t()]) ::
          {:ok, String.t(), {:literal, String.t()} | :stdin, String.t(), boolean()} | :error
  def parse_send(args) do
    try do
      {opts, positional, invalid} =
        OptionParser.parse(args, strict: [stdin: :boolean, msg_id: :string])

      stdin? = Keyword.get(opts, :stdin, false)

      msg_id = msg_id_or_invalid(opts)

      case {invalid, msg_id, stdin?, positional} do
        {_, :invalid, _, _} ->
          :error

        {[], {id, minted?}, true, [pane_id]} when is_binary(pane_id) and pane_id != "" ->
          {:ok, pane_id, :stdin, id, minted?}

        {[], {id, minted?}, false, [pane_id, text]}
        when is_binary(pane_id) and pane_id != "" and is_binary(text) ->
          {:ok, pane_id, {:literal, text}, id, minted?}

        _ ->
          :error
      end
    rescue
      _ -> :error
    end
  end

  @doc false
  @spec parse_consult([String.t()]) :: {:ok, map()} | :error
  def parse_consult(args), do: AiPair.CLI.Consult.parse_args(args)

  defp msg_id_or_invalid(opts) do
    case Keyword.fetch(opts, :msg_id) do
      :error -> {mint_msg_id(), true}
      {:ok, ""} -> :invalid
      {:ok, v} when is_binary(v) -> {v, false}
    end
  end

  defp mint_msg_id do
    "m_" <>
      Integer.to_string(:erlang.system_time(:nanosecond)) <>
      "_" <>
      Base.encode16(:rand.bytes(4), case: :lower)
  end

  defp read_send_text({:literal, text}), do: {:ok, text}

  defp read_send_text(:stdin) do
    case IO.read(:stdio, :eof) do
      :eof -> {:ok, ""}
      {:error, reason} -> {:error, {:stdin_read, reason}}
      data when is_binary(data) -> {:ok, data}
    end
  end

  defp send_text(pane_id, text, msg_id, msg_id_minted?) do
    payload =
      %{"cmd" => "send", "pane_id" => pane_id, "text" => text}
      |> maybe_put("msg_id", msg_id)

    extra_attrs =
      %{"messaging.message.id" => msg_id}
      |> maybe_put("messaging.message.id_minted", minted_attr(msg_id_minted?))

    run_cmd("send", payload, extra_attrs)
  end

  defp minted_attr(true), do: true
  defp minted_attr(false), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp pane_status(pane_id) do
    run_cmd("pane_status", %{"cmd" => "pane_status", "pane_id" => pane_id})
  end

  defp detach(pane_id) do
    run_cmd("detach", %{"cmd" => "detach_pane", "pane_id" => pane_id})
  end

  @doc """
  Builds the attach business payload; transport adds the current trace context.

  Exactly `cmd` and `pane_id`, plus `agent` only when one is given and
  `durable` only when requested. `maybe_put/3` drops nil, not false, so
  "not durable" maps to nil: that keeps `durable` off the legacy frame
  entirely rather than sending `durable: false`, which would still be a
  new key. The CLI does not yet expose a durable attach; `attach/2`
  always passes `false`.
  """
  @spec attach_payload(String.t(), String.t() | nil, boolean()) :: map()
  def attach_payload(pane_id, agent, durable?) do
    %{"cmd" => "attach_pane", "pane_id" => pane_id}
    |> maybe_put("agent", agent)
    |> maybe_put("durable", durable_attr(durable?))
  end

  defp durable_attr(true), do: true
  defp durable_attr(false), do: nil

  defp attach(pane_id, agent) do
    run_cmd("attach", attach_payload(pane_id, agent, false))
  end

  defp ensure_socket_exists(path) do
    if File.exists?(path) do
      :ok
    else
      {:error, {:no_socket, path}}
    end
  end

  defp connect(path) do
    :gen_tcp.connect(
      {:local, path},
      0,
      [
        :binary,
        {:packet, 4},
        {:packet_size, @max_frame_bytes},
        {:active, false}
      ],
      @connect_timeout_ms
    )
  end

  defp format_error({:no_socket, path}),
    do: "daemon socket not found at #{path}; is the daemon running?"

  defp format_error(:econnrefused),
    do: "daemon refused connection (stale socket?)"

  defp format_error(:timeout), do: "timeout waiting for daemon reply"

  defp format_error(:protocol_reply_mismatch),
    do: "protocol_error: daemon reply does not match the requested protocol or identity"

  defp format_error(message) when is_binary(message), do: message
  defp format_error({:invalid_json, _}), do: "daemon returned invalid JSON"
  defp format_error({:stdin_read, reason}), do: "failed to read stdin: " <> inspect(reason)
  defp format_error(other), do: inspect(other)

  defp print_usage(target) do
    out =
      """
      Usage: ai-pair [COMMAND]

      Commands:
        ping                            Ping the daemon and print the reply (default)
        ping --protocol-version 2      Report durable delivery capabilities.
        sessions [--protocol-version 2] Read sessions after capability preflight.
        attach <pane_id> [--agent A]    Attach a tmux pane to the daemon's tracker.
                                        --agent selects a fingerprint classifier
                                        (claude_code | codex_cli). Default: stub.
        send <pane_id> <text>           Enqueue text for delivery to a pane. Use
        send <pane_id> --stdin          --stdin to read text from stdin instead.
                                        --msg-id <id> stamps msg.id on the
                                        cli.send/ipc.send/pane.paste spans and
                                        also records it in the IPC payload.
                                        Add --protocol-version 2 with a stable
                                        --msg-id snd_<64 lowercase hex digits>
                                        for durable duplicate suppression.
        reconcile <pane_id>            Requires --protocol-version 2, --msg-id,
                                        --payload-hash sha256:<64 hex digits>.
                                        Optional --wait-ms 0..2000 (default 250).
        consult <text...>               Stage a consultation envelope for the
        consult --stdin                 peer pane. Add --wait [secs] to print
                                        the correlated reply body; default wait
                                        is 600s. Optional: --peer <agent>,
                                        --msg-id <id>.
        pane_status <pane_id>           Print state + pending_count + classifier
                                        for a registered pane (JSON envelope).
        detach <pane_id>                Hard-shutdown a registered pane SM
                                        (DynamicSupervisor.terminate_child).
        help                            Show this help

      Connects to the daemon socket at
      $HOME/.ai-agent-inbox/ai-pair/sock/ai-pair.sock.
      Set $AI_PAIR_DAEMON_SOCK to override (tests / out-of-tree daemons).
      """

    case target do
      :stdio -> IO.puts(out)
      :stderr -> IO.puts(:stderr, out)
    end

    true
  end
end
