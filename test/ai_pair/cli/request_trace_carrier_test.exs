defmodule AiPair.CLI.RequestTraceCarrierTest do
  @moduledoc """
  The OpenTelemetry trace carrier may annotate a CLI request frame; it may never rewrite it.

  `AiPair.CLI.Client.request/1` injects the current trace context into the JSON frame. The
  daemon reads only `traceparent` and `tracestate` from a frame (`server.ex`
  `extract_remote_ctx/1`), and the sessions request admits exactly
  `cmd protocol_version traceparent tracestate` (`sessions.ex` `@request_keys`). So:

    * a command key (`cmd`, `pane_id`, `msg_id`, `text`, `protocol_version`, ...) always
      keeps the command's value, whatever key a configured propagator emits;
    * `traceparent` and `tracestate` are forwarded;
    * no other carrier key reaches the frame, and the request is never refused for it.

  The propagator is installed through `:opentelemetry.set_text_map_injector/1`, which is
  what the running SDK reads on every inject; changing application config at runtime
  would not take effect. The original injector is captured first and restored.

  Each assertion is made through a checker that returns `:ok` or `{:error, reason}`, and
  controls C1-C6 show that every checker reports a violation when handed one.
  """

  use ExUnit.Case, async: false

  alias AiPair.CLI.Client

  require OpenTelemetry.Tracer, as: Tracer

  @trace_keys ~w(traceparent tracestate)
  @sessions_request_keys ~w(cmd protocol_version traceparent tracestate)
  @tracestate "c001vendor=opaque"
  @remote_traceparent "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"

  # Every key the colliding propagator emits: command keys of the send and sessions
  # frames, plus two keys no frame may carry.
  @colliding %{
    "cmd" => "detach_pane",
    "pane_id" => "%hijacked",
    "msg_id" => "snd_" <> String.duplicate("f", 64),
    "text" => "injected text",
    "protocol_version" => 1,
    "baggage" => "k=v",
    "x-extra" => "nope"
  }

  @send %{
    "cmd" => "send",
    "protocol_version" => 2,
    "pane_id" => "%carrier",
    "msg_id" => "snd_" <> String.duplicate("a", 64),
    "text" => "real text"
  }

  @sessions %{"cmd" => "sessions", "protocol_version" => 2}

  defmodule CollidingPropagator do
    @moduledoc false
    @behaviour :otel_propagator_text_map

    @impl true
    def fields(pairs), do: Map.keys(pairs)

    @impl true
    def inject(_ctx, carrier, set, pairs),
      do: Enum.reduce(pairs, carrier, fn {key, value}, acc -> set.(key, value, acc) end)

    @impl true
    def extract(ctx, _carrier, _keys, _get, _pairs), do: ctx
  end

  setup do
    original = :opentelemetry.get_text_map_injector()
    on_exit(fn -> :opentelemetry.set_text_map_injector(original) end)

    root = Path.join(System.tmp_dir!(), "trace_carrier_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    socket = Path.join(root, "carrier.sock")
    previous_sock = System.get_env("AI_PAIR_DAEMON_SOCK")
    System.put_env("AI_PAIR_DAEMON_SOCK", socket)

    on_exit(fn ->
      if previous_sock,
        do: System.put_env("AI_PAIR_DAEMON_SOCK", previous_sock),
        else: System.delete_env("AI_PAIR_DAEMON_SOCK")

      File.rm_rf!(root)
    end)

    {:ok, original: original, socket: socket}
  end

  test "W0: inside a span the carrier really carries traceparent and tracestate" do
    carrier = in_remote_child_span(fn -> :otel_propagator_text_map.inject([]) |> Map.new() end)
    assert check_trace_present(carrier) == :ok
    assert carrier["tracestate"] == @tracestate
  end

  test "a colliding propagator cannot rewrite a send frame's command keys", c do
    frame =
      with_injector(colliding_injector(), fn ->
        in_remote_child_span(fn -> request!(c.socket, @send) end)
      end)

    assert check_command_wins(frame, @send) == :ok
    assert check_trace_present(frame) == :ok
    assert check_no_extra(frame, @send) == :ok
  end

  test "a colliding propagator cannot add keys to a sessions frame", c do
    frame =
      with_injector(colliding_injector(), fn ->
        in_remote_child_span(fn -> request!(c.socket, @sessions) end)
      end)

    assert check_command_wins(frame, @sessions) == :ok
    assert check_trace_present(frame) == :ok
    assert check_sessions_keys(frame) == :ok
  end

  test "the full CLI send path keeps its command keys under a colliding propagator", c do
    args = ["send", @send["pane_id"], @send["text"], "--msg-id", @send["msg_id"]]
    args = args ++ ["--protocol-version", "2"]

    reply = %{
      "ok" => true,
      "protocol_version" => 2,
      "status" => "sent",
      "msg_id" => @send["msg_id"],
      "pane_id" => @send["pane_id"]
    }

    {exit, frame} =
      with_injector(colliding_injector(), fn ->
        exchange!(c.socket, reply, fn ->
          ExUnit.CaptureIO.capture_io(fn -> send(self(), {:exit, Client.main(args)}) end)
          assert_received {:exit, exit}
          exit
        end)
      end)

    assert exit == 0, "the request is never refused because of the carrier"
    assert check_command_wins(frame, @send) == :ok
    assert Map.has_key?(frame, "traceparent"), "cli.send is a span, so traceparent is sent"
    assert check_no_extra(frame, @send) == :ok
  end

  test "the original injector is restored", c do
    _frame =
      with_injector(colliding_injector(), fn ->
        in_remote_child_span(fn -> request!(c.socket, @sessions) end)
      end)

    assert check_restored(c.original) == :ok
  end

  describe "controls: every checker reports a violation" do
    test "C1: check_command_wins fails when a command value is replaced" do
      assert {:error, _} = check_command_wins(Map.put(@send, "pane_id", "%hijacked"), @send)
      assert {:error, _} = check_command_wins(Map.delete(@send, "cmd"), @send)
    end

    test "C2: check_trace_present fails without traceparent or tracestate" do
      full = %{"traceparent" => @remote_traceparent, "tracestate" => @tracestate}
      assert {:error, _} = check_trace_present(Map.delete(full, "traceparent"))
      assert {:error, _} = check_trace_present(Map.delete(full, "tracestate"))
    end

    test "C3: check_no_extra fails on a foreign carrier key" do
      assert {:error, _} = check_no_extra(Map.put(@send, "baggage", "k=v"), @send)
    end

    test "C4: check_sessions_keys fails on a key the sessions request does not admit" do
      assert {:error, _} = check_sessions_keys(Map.put(@sessions, "baggage", "k=v"))
    end

    test "C5: check_restored fails while a different injector is installed", c do
      :opentelemetry.set_text_map_injector(colliding_injector())
      assert {:error, _} = check_restored(c.original)
      :opentelemetry.set_text_map_injector(c.original)
      assert check_restored(c.original) == :ok
    end

    test "C6: the colliding injector really emits every colliding key" do
      carrier =
        with_injector(colliding_injector(), fn ->
          in_remote_child_span(fn -> :otel_propagator_text_map.inject([]) |> Map.new() end)
        end)

      for {key, value} <- @colliding do
        assert carrier[key] == value, "the propagator must emit #{key}"
      end

      assert check_trace_present(carrier) == :ok
      assert {:error, _} = check_command_wins(Map.merge(@send, carrier), @send)
    end
  end

  # ===== checkers =====

  defp check_command_wins(frame, command) do
    wrong = for {key, value} <- command, Map.get(frame, key, :missing) !== value, do: key
    if wrong == [], do: :ok, else: {:error, {:command_keys_changed, wrong}}
  end

  defp check_trace_present(frame) do
    missing = Enum.reject(@trace_keys, &is_binary(frame[&1]))
    if missing == [], do: :ok, else: {:error, {:trace_keys_missing, missing}}
  end

  defp check_no_extra(frame, command) do
    extra = Map.keys(frame) -- (Map.keys(command) ++ @trace_keys)
    if extra == [], do: :ok, else: {:error, {:extra_keys, extra}}
  end

  defp check_sessions_keys(frame) do
    extra = Map.keys(frame) -- @sessions_request_keys
    if extra == [], do: :ok, else: {:error, {:not_admitted, extra}}
  end

  defp check_restored(original) do
    current = :opentelemetry.get_text_map_injector()
    if current == original, do: :ok, else: {:error, {:injector_not_restored, current}}
  end

  # ===== harness =====

  # The configured trace-context propagator first, then the colliding one, so the carrier
  # holds a real traceparent/tracestate plus every colliding key.
  defp colliding_injector,
    do:
      :otel_propagator_text_map_composite.create([
        :trace_context,
        {CollidingPropagator, @colliding}
      ])

  defp with_injector(injector, fun) do
    original = :opentelemetry.get_text_map_injector()
    :opentelemetry.set_text_map_injector(injector)

    try do
      fun.()
    after
      :opentelemetry.set_text_map_injector(original)
    end
  end

  # A child span of a remote parent that carries a tracestate, so the trace-context
  # propagator emits both traceparent and tracestate.
  defp in_remote_child_span(fun) do
    remote =
      :otel_propagator_text_map.extract_to(
        :otel_ctx.new(),
        :otel_propagator_trace_context,
        [{"traceparent", @remote_traceparent}, {"tracestate", @tracestate}]
      )

    token = :otel_ctx.attach(remote)

    try do
      Tracer.with_span "request_trace_carrier" do
        fun.()
      end
    after
      :otel_ctx.detach(token)
    end
  end

  defp request!(socket, command) do
    {{:ok, _reply}, frame} = exchange!(socket, %{"ok" => true}, fn -> Client.request(command) end)
    frame
  end

  # One bounded fake-daemon exchange: accepts one connection, captures the frame, answers
  # `reply`, and removes the socket path afterwards.
  defp exchange!(socket, reply, operation) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ifaddr: {:local, socket}, active: false, packet: 4])

    server =
      Task.async(fn ->
        {:ok, connection} = :gen_tcp.accept(listener, 1_000)

        try do
          {:ok, frame} = :gen_tcp.recv(connection, 0, 1_000)
          :ok = :gen_tcp.send(connection, Jason.encode!(reply))
          frame
        after
          :gen_tcp.close(connection)
        end
      end)

    try do
      result = operation.()
      {result, Jason.decode!(Task.await(server, 2_000))}
    after
      :gen_tcp.close(listener)
      Task.shutdown(server, :brutal_kill)
      File.rm(socket)
    end
  end
end
