defmodule AiPair.NS17F3TmuxErrorBytesTest do
  @moduledoc """
  RED rows for NS-17 finding F-3: a failed tmux payload call carries caller bytes.

  Governing scope: CLAUDE-ORRISD-F3-FIX-SOURCE-SCOPE-r2 (option 3a-full). Eight tests:
  seven RED rows (F3-T1, F3-T1E, F3-T2, F3-T3, F3-T4, F3-T5E, F3-T6) and one guard
  (F3-T5) that passes before and after the fix.

  Every row puts a token-shaped canary, built at run time, into the payload of
  `AiPair.Tmux.set_buffer/3` through a server whose `:tmux_bin` is a bash stub or a
  missing binary. Nothing here starts a tmux server. The SILENT stub writes only a
  control marker to stderr and exits 3. The ECHO stub writes its last argument (the
  payload) and then the marker to stderr, records its argv in a side file, and exits 3.

  Each row builds a fixed, ordered list of named sinks, runs every control first, and
  then asserts `leaks == []` with the message `"<ROW> canary found in: " <> inspect(leaks)`.
  No message interpolates the payload or the canary; controls report sizes, counts,
  statuses, class words or span names only. Assertions after the leak assertion pin the
  bounded shapes the fix produces and are not reached before it.
  """

  use ExUnit.Case, async: false

  import AiPair.Test.OtelHelper,
    only: [setup_otel_capture: 1, drain_spans: 0, span_name: 1, span_attrs: 1, span_status: 1]

  import ExUnit.CaptureLog, only: [with_log: 2]

  alias AiPair.Delivery.ReceiptStore
  alias AiPair.IPC.Server
  alias AiPair.Pane.StateMachine
  alias AiPair.PaneSupervisor
  alias AiPair.Test.MarkerClassifier

  @pipeline_spans ["pane.paste", "ipc.send", "tmux.set_buffer"]

  setup :setup_otel_capture

  setup do
    n = System.unique_integer([:positive])
    inbox = Path.join(System.tmp_dir!(), "ns17p_f3_" <> Integer.to_string(n))
    File.mkdir_p!(Path.join(inbox, "sock"))
    File.chmod!(Path.join(inbox, "sock"), 0o700)
    File.mkdir_p!(Path.join(inbox, "stub"))
    on_exit(fn -> File.rm_rf!(inbox) end)

    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    store = start_supervised!({ReceiptStore, inbox: inbox})
    start_supervised!({Server, inbox: inbox, name: :"ns17p_f3_server_#{n}", receipt_store: store})

    {:ok,
     n: n,
     inbox: inbox,
     store: store,
     canary: canary(),
     marker: control_marker(),
     pane: "%ns17p_" <> Integer.to_string(n),
     sock: Path.join(inbox, "sock/ai-pair.sock")}
  end

  describe "tmux boundary" do
    test "F3-T1 a non-zero set-buffer error carries no payload", c do
      payload = "x" <> c.canary
      check_inputs!(payload, c.marker)
      {bin, _side} = stub!(c, :silent)
      server = tmux!(c, bin)
      buf = buffer_name()

      assert {:error, err} = AiPair.Tmux.set_buffer(buf, payload, server),
             "F3-T1 control: set_buffer did not return an error"

      assert err.status == 3, "F3-T1 control: status " <> inspect(err.status)

      assert inspect(err.cmd) =~ buf,
             "F3-T1 control: buffer name absent, cmd length " <> inspect(length(err.cmd))

      sinks = [{"err.cmd", render(err.cmd)}, {"err.stderr", err.stderr}]
      leaks = for {name, hay} <- sinks, hit?(hay, c.canary), do: name

      assert leaks == [], "F3-T1 canary found in: " <> inspect(leaks)

      assert List.last(err.cmd) == payload_label(payload),
             "F3-T1 contract: last argv bytes " <> inspect(byte_size(List.last(err.cmd)))

      assert err.stderr == stderr_label(byte_size(c.marker) + 1, "nonzero_exit"),
             "F3-T1 contract: stderr bytes " <> inspect(byte_size(err.stderr))
    end

    test "F3-T1E an echoed payload leaves no bytes in the error or the tmux span", c do
      payload = "x" <> c.canary
      check_inputs!(payload, c.marker)
      {bin, side} = stub!(c, :echo)
      server = tmux!(c, bin)
      buf = buffer_name()

      assert {:error, err} = AiPair.Tmux.set_buffer(buf, payload, server),
             "F3-T1E control: set_buffer did not return an error"

      spans = spans_for!("F3-T1E", ["tmux.set_buffer"])
      argv = File.read!(side)

      assert argv =~ c.canary,
             "F3-T1E control: stub side file bytes " <> inspect(byte_size(argv))

      assert [span | _] = named(spans, "tmux.set_buffer"),
             "F3-T1E control: spans seen " <> inspect(Enum.map(spans, &span_name/1))

      attrs = span_attrs(span)

      assert attrs["tmux.payload_bytes"] == byte_size(payload),
             "F3-T1E control: payload_bytes " <> inspect(attrs["tmux.payload_bytes"])

      assert attrs["tmux.exit_status"] == 3,
             "F3-T1E control: exit_status " <> inspect(attrs["tmux.exit_status"])

      assert attrs["tmux.error_class"] == "nonzero_exit",
             "F3-T1E control: error_class " <> inspect(attrs["tmux.error_class"])

      sinks = [
        {"err.cmd", render(err.cmd)},
        {"err.stderr", err.stderr},
        {"span tmux.set_buffer status", statuses(spans, "tmux.set_buffer")}
      ]

      leaks = for {name, hay} <- sinks, hit?(hay, c.canary), do: name

      assert leaks == [], "F3-T1E canary found in: " <> inspect(leaks)

      n = byte_size(payload) + 1 + byte_size(c.marker) + 1

      assert err.stderr == stderr_label(n, "nonzero_exit"),
             "F3-T1E contract: stderr bytes " <> inspect(byte_size(err.stderr))
    end

    test "F3-T2 a missing tmux binary leaves no payload in the error or the log", c do
      payload = "x" <> c.canary
      check_inputs!(payload, c.marker)
      server = tmux!(c, absent_binary(c))
      buf = buffer_name()

      {result, log} =
        with_log([level: :debug], fn -> AiPair.Tmux.set_buffer(buf, payload, server) end)

      assert {:error, err} = result, "F3-T2 control: set_buffer did not return an error"
      assert err.status == -1, "F3-T2 control: status " <> inspect(err.status)

      assert log =~ "tmux binary not found on PATH",
             "F3-T2 control: missing-binary log absent, log bytes " <> inspect(byte_size(log))

      assert log =~ buf,
             "F3-T2 control: buffer name absent from log, log bytes " <>
               inspect(byte_size(log))

      assert inspect(err.cmd) =~ buf,
             "F3-T2 control: buffer name absent from cmd, cmd length " <>
               inspect(length(err.cmd))

      sinks = [{"log", log}, {"err.cmd", render(err.cmd)}, {"err.stderr", err.stderr}]
      leaks = for {name, hay} <- sinks, hit?(hay, c.canary), do: name

      assert leaks == [], "F3-T2 canary found in: " <> inspect(leaks)

      assert List.last(err.cmd) == payload_label(payload),
             "F3-T2 contract: last argv bytes " <> inspect(byte_size(List.last(err.cmd)))

      assert log =~ payload_label(payload),
             "F3-T2 contract: log bytes " <> inspect(byte_size(log))

      assert String.starts_with?(err.stderr, "<stderr:") and
               String.ends_with?(err.stderr, " bytes class=binary_not_found>"),
             "F3-T2 contract: stderr bytes " <> inspect(byte_size(err.stderr))
    end
  end

  describe "v1 send path" do
    test "F3-T3 an immediate v1 paste failure carries no payload", c do
      text = "a" <> c.canary
      check_inputs!(text, c.marker)
      {bin, _side} = stub!(c, :silent)
      server = tmux!(c, bin)

      {{reply, pane}, log} =
        with_log([level: :debug], fn ->
          pane = start_pane!(c, server, "IDLE_MARKER")

          try do
            assert await_state(pane.sm, :idle) == :ok, "F3-T3 control: pane never idle"
            {send_raw!(c, v1_frame(c, text)), pane}
          after
            PaneSupervisor.stop_pane(c.pane)
          end
        end)

      decoded = Jason.decode!(reply)
      spans = spans_for!("F3-T3", @pipeline_spans)
      seen = Agent.get(pane.seen, & &1)

      assert decoded["error"] == "paste_failed",
             "F3-T3 control: error " <> inspect(decoded["error"])

      assert is_binary(decoded["detail"]) and decoded["detail"] != "",
             "F3-T3 control: detail bytes " <> inspect(detail_bytes(decoded))

      assert paste_bytes(spans) == [byte_size(text)],
             "F3-T3 control: paste.bytes " <> inspect(paste_bytes(spans))

      assert Enum.any?(seen, &(&1 == text)),
             "F3-T3 control: adapter received bytes " <> inspect(Enum.map(seen, &byte_size/1))

      sinks = pipeline_sinks(reply, spans, log)
      leaks = for {name, hay} <- sinks, hit?(hay, c.canary), do: name

      assert leaks == [], "F3-T3 canary found in: " <> inspect(leaks)

      assert decoded["detail"] =~ "<payload:",
             "F3-T3 contract: detail bytes " <> inspect(detail_bytes(decoded))
    end

    test "F3-T4 a drained v1 paste failure carries no payload", c do
      text = "a" <> c.canary
      check_inputs!(text, c.marker)
      {bin, _side} = stub!(c, :silent)
      server = tmux!(c, bin)

      {{reply, pane, drained}, log} =
        with_log([level: :debug], fn ->
          pane = start_pane!(c, server, "BUSY_MARKER")

          try do
            assert await_state(pane.sm, :busy) == :ok, "F3-T4 control: pane never busy"
            reply = send_raw!(c, v1_frame(c, text))
            Agent.update(pane.screen, fn _ -> "IDLE_MARKER" end)

            drained =
              wait_until(fn ->
                Agent.get(pane.seen, &(text in &1)) and StateMachine.pending_count(pane.sm) == 0
              end)

            {reply, pane, drained}
          after
            PaneSupervisor.stop_pane(c.pane)
          end
        end)

      decoded = Jason.decode!(reply)
      spans = spans_for!("F3-T4", @pipeline_spans)
      seen = Agent.get(pane.seen, & &1)

      assert decoded["status"] == "queued",
             "F3-T4 control: status " <> inspect(decoded["status"])

      assert drained, "F3-T4 control: drain not observed, adapter calls " <> inspect(length(seen))

      assert log =~ "dropping queued send" and log =~ "text bytes=#{byte_size(text)}",
             "F3-T4 control: drain warning absent, log bytes " <> inspect(byte_size(log))

      assert Enum.any?(seen, &(&1 == text)),
             "F3-T4 control: adapter received bytes " <> inspect(Enum.map(seen, &byte_size/1))

      sinks = pipeline_sinks(reply, spans, log)
      leaks = for {name, hay} <- sinks, hit?(hay, c.canary), do: name

      assert leaks == [], "F3-T4 canary found in: " <> inspect(leaks)

      assert log =~ "<payload:", "F3-T4 contract: log bytes " <> inspect(byte_size(log))
    end
  end

  describe "v2 send path" do
    test "F3-T5 guard: a v2 paste failure through the silent stub carries no payload", c do
      {reply, spans, log, seen, _side} = v2_row(c, "F3-T5", :silent)
      assert_v2_controls("F3-T5", c, reply, spans, seen)

      sinks = pipeline_sinks(reply, spans, log)
      leaks = for {name, hay} <- sinks, hit?(hay, c.canary), do: name

      assert leaks == [], "F3-T5 canary found in: " <> inspect(leaks)
    end

    test "F3-T5E an echoed payload leaves no bytes in the v2 tmux span", c do
      {reply, spans, log, seen, side} = v2_row(c, "F3-T5E", :echo)
      assert_v2_controls("F3-T5E", c, reply, spans, seen)
      argv = File.read!(side)

      assert argv =~ c.canary,
             "F3-T5E control: stub side file bytes " <> inspect(byte_size(argv))

      sinks = pipeline_sinks(reply, spans, log)
      leaks = for {name, hay} <- sinks, hit?(hay, c.canary), do: name

      assert leaks == [], "F3-T5E canary found in: " <> inspect(leaks)

      status = statuses(spans, "tmux.set_buffer")

      assert status =~ "<stderr:",
             "F3-T5E contract: status bytes " <> inspect(byte_size(status))
    end

    test "F3-T6 a missing tmux binary on the v2 path leaves no payload in the log", c do
      {reply, spans, log, seen, _side} = v2_row(c, "F3-T6", :absent)
      assert_v2_controls("F3-T6", c, reply, spans, seen)

      assert log =~ "tmux binary not found on PATH",
             "F3-T6 control: missing-binary log absent, log bytes " <> inspect(byte_size(log))

      sinks = pipeline_sinks(reply, spans, log)
      leaks = for {name, hay} <- sinks, hit?(hay, c.canary), do: name

      assert leaks == [], "F3-T6 canary found in: " <> inspect(leaks)

      assert log =~ "<payload:", "F3-T6 contract: log bytes " <> inspect(byte_size(log))
    end
  end

  # ===== v2 row driver and controls =====

  defp v2_row(c, row, kind) do
    text = "a" <> c.canary
    check_inputs!(text, c.marker)

    {bin, side} =
      case kind do
        :absent -> {absent_binary(c), nil}
        stub -> stub!(c, stub)
      end

    server = tmux!(c, bin)

    {{reply, pane}, log} =
      with_log([level: :debug], fn ->
        pane = start_pane!(c, server, "IDLE_MARKER")

        try do
          assert await_state(pane.sm, :idle) == :ok, row <> " control: pane never idle"
          {send_raw!(c, v2_frame(c, row, text)), pane}
        after
          PaneSupervisor.stop_pane(c.pane)
        end
      end)

    spans = spans_for!(row, @pipeline_spans)
    {reply, spans, log, Agent.get(pane.seen, & &1), side}
  end

  defp assert_v2_controls(row, c, reply, spans, seen) do
    decoded = Jason.decode!(reply)
    id = msg_id(c, row)

    assert decoded["error"] == "paste_failed" and not Map.has_key?(decoded, "detail"),
           row <> " control: error " <> inspect(decoded["error"])

    assert decoded["msg_id"] == id and decoded["pane_id"] == c.pane,
           row <> " control: echoed identity keys " <> inspect(Map.keys(decoded))

    last = receipt_statuses(c, id) |> List.last()
    assert last == {1, "ambiguous"}, row <> " control: last receipt " <> inspect(last)

    assert Enum.any?(seen, &(&1 == "a" <> c.canary)),
           row <> " control: adapter received bytes " <> inspect(Enum.map(seen, &byte_size/1))

    assert named(spans, "pane.paste") != [],
           row <>
             " control: span pane.paste missing; spans seen: " <>
             inspect(Enum.map(spans, &span_name/1))
  end

  # ===== sinks =====

  defp pipeline_sinks(reply, spans, log) do
    paste_status = statuses(spans, "pane.paste")
    ipc_attrs = render(Enum.map(named(spans, "ipc.send"), &span_attrs/1))
    tmux_status = statuses(spans, "tmux.set_buffer")

    [
      {"reply", reply},
      {"span pane.paste status", paste_status},
      {"span ipc.send attributes", ipc_attrs},
      {"span tmux.set_buffer status", tmux_status},
      {"log", log}
    ]
  end

  defp statuses(spans, name), do: render(Enum.map(named(spans, name), &span_status/1))
  defp named(spans, name), do: Enum.filter(spans, &(span_name(&1) == name))

  defp paste_bytes(spans),
    do: Enum.map(named(spans, "pane.paste"), &span_attrs(&1)["paste.bytes"])

  defp detail_bytes(%{"detail" => detail}) when is_binary(detail), do: byte_size(detail)
  defp detail_bytes(_decoded), do: nil

  # The spans a row's sinks read, with presence as named controls: a channel whose span
  # never arrived fails here, before the leak assertion, instead of counting as clean.
  defp spans_for!(row, required) do
    {status, spans} = gather(required)
    names = Enum.map(spans, &span_name/1)

    assert status == :complete,
           row <> " control: spans incomplete at deadline; spans seen: " <> inspect(names)

    for name <- required do
      assert name in names,
             row <> " control: span " <> name <> " missing; spans seen: " <> inspect(names)
    end

    spans
  end

  # Collects exported spans until every required name has been seen, then takes whatever
  # else arrives in a short grace window. The result says which: `{:complete, spans}`, or
  # `{:partial, spans}` when the deadline passed first.
  defp gather(required, timeout \\ 1_000) do
    gather_loop(required, System.monotonic_time(:millisecond) + timeout, [])
  end

  defp gather_loop(required, deadline, acc) do
    names = Enum.map(acc, &span_name/1)
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    cond do
      Enum.all?(required, &(&1 in names)) ->
        Process.sleep(50)
        {:complete, acc ++ drain_spans()}

      remaining == 0 ->
        {:partial, acc}

      true ->
        receive do
          {:span, span} -> gather_loop(required, deadline, acc ++ [span])
        after
          remaining -> {:partial, acc}
        end
    end
  end

  defp render(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  defp hit?(haystack, canary) do
    upper = Base.encode16(canary)
    lower = Base.encode16(canary, case: :lower)
    Enum.any?([canary, Base.encode64(canary), upper, lower], &String.contains?(haystack, &1))
  end

  # ===== runtime values =====

  # Token-shaped canary built at run time; the source never holds the joined prefix.
  defp canary do
    prefix = Enum.join(["s", "k-ant-"])
    prefix <> "ns17p" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
  end

  defp control_marker, do: "ns17p_ctl_" <> Integer.to_string(System.unique_integer([:positive]))
  defp buffer_name, do: "ns17p_buf_" <> Integer.to_string(System.unique_integer([:positive]))
  defp absent_binary(c), do: "ns17p_absent_" <> Integer.to_string(c.n)
  defp payload_label(payload), do: "<payload:#{byte_size(payload)} bytes>"
  defp stderr_label(bytes, class), do: "<stderr:#{bytes} bytes class=#{class}>"

  defp check_inputs!(payload, marker) do
    assert byte_size(payload) >= 27,
           "input control: payload bytes " <> inspect(byte_size(payload))

    for {label, value} <- [payload: payload, marker: marker], bad <- ["\n", <<0>>, "'"] do
      refute String.contains?(value, bad),
             "input control: #{label} has a forbidden byte, bytes " <> inspect(byte_size(value))
    end
  end

  # ===== stubs and servers =====

  defp stub!(c, kind) do
    dir = Path.join(c.inbox, "stub")
    path = Path.join(dir, "tmux-" <> Atom.to_string(kind))
    side = Path.join(dir, "argv-" <> Atom.to_string(kind))
    File.write!(path, stub_body(kind, c.marker, side))
    File.chmod!(path, 0o700)
    {path, side}
  end

  defp stub_body(:silent, marker, _side) do
    Enum.join(
      [
        ~S|#!/usr/bin/env bash|,
        ~S|printf '%s\n' | <> quote_single(marker) <> ~S| >&2|,
        "exit 3",
        ""
      ],
      "\n"
    )
  end

  defp stub_body(:echo, marker, side) do
    Enum.join(
      [
        ~S|#!/usr/bin/env bash|,
        ~S|printf '%s\n' "${@: -1}" >&2|,
        ~S|printf '%s\n' | <> quote_single(marker) <> ~S| >&2|,
        ~S|{ for arg in "$@"; do printf '%s\037' "$arg"; done; printf '\n'; } >> | <>
          quote_single(side),
        "exit 3",
        ""
      ],
      "\n"
    )
  end

  defp quote_single(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp tmux!(c, bin) do
    name = :"ns17p_f3_tmux_#{c.n}_#{System.unique_integer([:positive])}"
    socket = "ns17p_f3_sock_" <> Integer.to_string(c.n)
    opts = [name: name, tmux_bin: bin, socket_name: socket]
    start_supervised!({AiPair.Tmux, opts}, id: {:tmux, name})
    name
  end

  # ===== pane, frames and receipts =====

  # Each unlinked Agent gets its cleanup the moment it starts, so a failed pane start
  # leaks neither. The pane's own stop is registered only after it started; on_exit runs
  # callbacks in reverse order, so the pane stops before either Agent.
  defp start_pane!(c, server, initial_screen) do
    {:ok, screen} = Agent.start(fn -> initial_screen end)
    on_exit(fn -> stop_agent(screen) end)
    {:ok, seen} = Agent.start(fn -> [] end)
    on_exit(fn -> stop_agent(seen) end)

    paste_fn = fn _pane_id, text ->
      Agent.update(seen, &[text | &1])
      AiPair.Tmux.set_buffer(buffer_name(), text, server)
    end

    {:ok, sm} =
      PaneSupervisor.start_pane(c.pane,
        receipt_store: c.store,
        capture_fn: fn _pane_id -> {:ok, Agent.get(screen, & &1)} end,
        paste_fn: paste_fn,
        classifier: MarkerClassifier,
        poll_interval_ms: 5,
        idle_debounce_ms: 0
      )

    on_exit(fn -> stop_started_pane(c.pane) end)
    %{sm: sm, screen: screen, seen: seen}
  end

  # Tolerates a pane that is already stopped (`{:error, :not_found}`) or exiting.
  defp stop_started_pane(pane_id) do
    case PaneSupervisor.stop_pane(pane_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp stop_agent(agent) do
    if Process.alive?(agent), do: Agent.stop(agent)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp v1_frame(c, text), do: %{"cmd" => "send", "pane_id" => c.pane, "text" => text}

  defp v2_frame(c, row, text) do
    %{
      "cmd" => "send",
      "protocol_version" => 2,
      "pane_id" => c.pane,
      "msg_id" => msg_id(c, row),
      "text" => text
    }
  end

  defp msg_id(c, row),
    do: "snd_" <> Base.encode16(:crypto.hash(:sha256, "#{row}-#{c.n}"), case: :lower)

  # Returns the raw reply bytes, so the reply sink is exactly what the socket carried.
  defp send_raw!(c, frame) do
    {:ok, client} =
      :gen_tcp.connect({:local, c.sock}, 0, [:binary, {:active, false}, {:packet, 4}], 1_000)

    try do
      :ok = :gen_tcp.send(client, Jason.encode!(frame))
      {:ok, bytes} = :gen_tcp.recv(client, 0, 5_000)
      bytes
    after
      :gen_tcp.close(client)
    end
  end

  defp receipt_statuses(c, id) do
    c.store
    |> ReceiptStore.path()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["message_id"] == id))
    |> Enum.map(&{&1["delivery_attempt"], &1["status"]})
  end

  defp await_state(sm, target, timeout \\ 2_000) do
    if wait_until(fn -> StateMachine.state(sm) == target end, timeout),
      do: :ok,
      else: {:timeout, StateMachine.state(sm)}
  end

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_loop(fun, deadline)
  end

  defp wait_loop(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(5)
        wait_loop(fun, deadline)
    end
  end
end
