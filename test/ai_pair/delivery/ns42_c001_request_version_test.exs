defmodule AiPair.Delivery.NS42C001RequestVersionTest do
  @moduledoc """
  NS-42.C.001 (protocol-version selection), request side.

  Register failure controls: "Missing, noninteger or mismatched protocol_version on a
  selected v2 exchange fails. Capability ping/send/reconcile must explicitly select
  integer 2 despite changed CLI defaults. A versionless legacy request must remain v1, not
  be rejected for lacking the v2 field."

  W2, the daemon's request grammar, over a real `ReceiptStore`, `AiPair.IPC.Server` and a
  pane registered through `PaneSupervisor.start_pane/2`. `server.ex:383-397` reads
  `Map.get(params, "protocol_version", 1)` and matches only integer 1 and integer 2. Every
  other value -- `"2"`, `2.0`, `true`, JSON `null`, `[2]`, and the mismatched integer `3`
  -- reaches `Delivery.unsupported/1` (`delivery.ex:58-59`): `ok: false`,
  `error: "unsupported_protocol_version"`, no outcome, no capabilities, no admission.
  Controls: the same frames with integer 2 succeed (C1), and a ping with the key absent is
  answered as v1 rather than refused (C2).

  A3, the CLI caller under altered ambient defaults. With plausible ambient overrides set
  (environment variables and an `:ai_pair` application-env key), `Client.main/1` still
  sends `protocol_version` as the integer 2 (`===`, so `2.0` fails) for ping, send and
  reconcile when `--protocol-version 2` is given, and sends the legacy shape with no
  `protocol_version` key for a flagless send or ping.

  The structural rows are a BOUNDED WITNESS ABOUT THE CURRENT SOURCE ONLY. They pin the
  runtime-configuration reads that `lib/ai_pair/cli/client.ex` makes today (its
  `System.get_env/1` call sites are exactly `AI_PAIR_DAEMON_SOCK` and `AI_PAIR_ARGV_B64`,
  and it makes no `Application.get_env`/`fetch_env`/`compile_env`, `:persistent_term`,
  `System.fetch_env` or `:os.getenv` read), and they check that the two shell wrappers
  forward argv without naming a version. A future read of that kind fails a row here; C3
  shows the extractor reports one. These rows do NOT prove that no ambient default can
  exist anywhere. The OpenTelemetry propagation carrier is no longer such a route:
  `Client.request/1` keeps only the allowlisted `traceparent` and `tracestate` from it
  (`client.ex:33`, `@trace_carrier_keys`) and merges the command over what remains
  (`client.ex:404-409`, `Map.take/2` then `Map.merge(carrier, cmd)`), so command keys,
  `protocol_version` included, always win. That is pinned against a colliding propagator in
  `test/ai_pair/cli/request_trace_carrier_test.exs`. The row here pins only that, with the
  configured propagators, the carrier keys are the trace-context set and the frame's
  version is untouched. Whether "no ambient default exists, pinned structurally" is an
  acceptable witness for the register row is the reviewers' decision.

  `async: false`: the file sets environment variables and application env.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AiPair.CLI.Client
  alias AiPair.Delivery.{Payload, ReceiptStore}
  alias AiPair.IPC.Server
  alias AiPair.Pane.StateMachine
  alias AiPair.PaneSupervisor
  alias AiPair.Test.MarkerClassifier

  require OpenTelemetry.Tracer, as: Tracer

  @client_source Path.expand("../../../lib/ai_pair/cli/client.ex", __DIR__)
  @release_wrapper Path.expand("../../../rel/overlays/bin/ai-pair", __DIR__)
  @ap_wrapper Path.expand("../../../nix/files/ap.sh", __DIR__)
  @config_dir Path.expand("../../../config", __DIR__)

  # Values that are not the integer 2 and not a legacy (absent or integer 1) version.
  @bad_versions ["2", 2.0, true, nil, [2], 3]

  # Keys the configured OpenTelemetry text-map propagators may add to a frame.
  @trace_keys ~w(traceparent tracestate baggage)

  # The environment variables through which `client.ex` reads anything today.
  @known_env_reads MapSet.new(~w(AI_PAIR_DAEMON_SOCK AI_PAIR_ARGV_B64))

  @text "c001 bytes"
  @cli_id "snd_" <> String.duplicate("c1", 32)
  @cli_pane "%c001"
  @cli_hash "sha256:" <> String.duplicate("d0", 32)

  describe "W2: the daemon refuses a v2 request whose version is not the integer 2" do
    setup :daemon

    test "ping, send and reconcile with a noninteger or mismatched version are refused " <>
           "without effect",
         c do
      before = File.read!(c.log)

      for verb <- ~w(ping send reconcile), version <- @bad_versions do
        frame = c |> frame(verb, id(c, "w2-#{verb}")) |> Map.put("protocol_version", version)
        encoded = Jason.encode!(frame)

        # The key is really on the wire with this value, not dropped by the encoder.
        assert Map.fetch!(Jason.decode!(encoded), "protocol_version") === version

        reply = send_raw!(c.sock, encoded)
        label = "#{verb} with protocol_version #{inspect(version)}"

        assert reply["ok"] == false, label
        assert reply["error"] == "unsupported_protocol_version", label
        refute Map.has_key?(reply, "outcome"), "#{label}: a refusal states no outcome"
        refute Map.has_key?(reply, "capabilities"), "#{label}: a refusal advertises nothing"
      end

      assert File.read!(c.log) == before, "no refused request may admit an attempt"
      assert pastes(c) == 0, "no refused request may reach the paste"
    end

    test "C1: the same frames with the integer 2 succeed", c do
      assert %{"ok" => true, "protocol_version" => 2, "capabilities" => capabilities} =
               send_frame!(c.sock, frame(c, "ping", nil))

      assert "delivery_reconcile" in capabilities

      id = id(c, "c1-send")
      assert %{"ok" => true, "status" => "sent"} = send_frame!(c.sock, frame(c, "send", id))
      assert pastes(c) == 1

      assert %{"ok" => true, "outcome" => "delivered", "delivery_attempt" => 1} =
               send_frame!(c.sock, frame(c, "reconcile", id))
    end

    test "C2: a versionless ping stays v1 and is not refused for lacking the v2 field", c do
      for request <- [%{"cmd" => "ping"}, %{"cmd" => "ping", "protocol_version" => 1}] do
        reply = send_frame!(c.sock, request)

        assert reply["ok"] == true, inspect(request)
        assert is_binary(reply["pong"])
        refute reply["error"] == "unsupported_protocol_version"
        refute Map.has_key?(reply, "capabilities"), "the v1 ping reply advertises nothing"
        refute Map.has_key?(reply, "protocol_version"), "the v1 reply does not name a version"
      end
    end
  end

  describe "A3: the CLI selects integer 2 only from the explicit flag" do
    setup :fake_daemon

    test "ping, send and reconcile send the integer 2 despite altered ambient defaults", c do
      with_ambient_overrides(fn ->
        for verb <- ~w(ping send reconcile) do
          {args, reply} = versioned(verb)
          {exit, frame} = exchange!(c.socket, reply, fn -> Client.main(args) end)

          assert exit == 0, "#{verb} must succeed against a bound v2 reply"
          assert Map.fetch!(frame, "protocol_version") === 2, "#{verb}: strictly the integer 2"
          assert frame["cmd"] == verb

          assert frame |> Map.keys() |> Enum.reject(&(&1 in @trace_keys)) |> Enum.sort() ==
                   expected_keys(verb)
        end
      end)
    end

    test "a flagless send or ping stays legacy under the same ambient overrides", c do
      with_ambient_overrides(fn ->
        {exit, frame} =
          exchange!(c.socket, %{"ok" => true, "status" => "sent"}, fn ->
            Client.main(["send", "%c001", "input", "--msg-id", "legacy-id"])
          end)

        assert exit == 0
        refute Map.has_key?(frame, "protocol_version"), "a flagless send is the v1 shape"

        assert Map.drop(frame, @trace_keys) == %{
                 "cmd" => "send",
                 "pane_id" => "%c001",
                 "text" => "input",
                 "msg_id" => "legacy-id"
               }

        {exit, frame} =
          exchange!(c.socket, %{"ok" => true, "pong" => "x"}, fn -> Client.main(["ping"]) end)

        assert exit == 0
        assert Map.drop(frame, @trace_keys) == %{"cmd" => "ping"}
      end)
    end

    test "the argv carrier forwards the version flag unchanged" do
      argv = ["send", @cli_pane, "input", "--msg-id", @cli_id, "--protocol-version", "2"]
      previous = System.get_env("AI_PAIR_ARGV_B64")
      on_exit(fn -> restore_env("AI_PAIR_ARGV_B64", previous) end)

      # The release wrapper's encoding: `printf '%s\0' "$@" | base64`.
      System.put_env("AI_PAIR_ARGV_B64", Base.encode64(Enum.map_join(argv, &(&1 <> <<0>>))))
      assert Client.argv() == argv

      assert {:ok, %{"protocol_version" => 2}, {:literal, "input"}} =
               Client.parse_versioned("send", tl(Client.argv()))

      # A non-2 flag value is refused by the parser, not coerced (client.ex:283).
      assert Client.parse_versioned("ping", ["--protocol-version", "1"]) == :error
      assert Client.parse_versioned("ping", ["--protocol-version", "3"]) == :error
    end

    test "with the configured propagators the trace carrier cannot carry a version" do
      Tracer.with_span "ns42_c001.carrier" do
        carrier = :otel_propagator_text_map.inject([]) |> Map.new()

        # Not vacuous: inside a span the configured propagators do emit a carrier.
        assert Map.has_key?(carrier, "traceparent")

        assert carrier |> Map.keys() |> Enum.all?(&(&1 in @trace_keys)),
               "carrier keys: #{inspect(Map.keys(carrier))}"

        refute Map.has_key?(carrier, "protocol_version")
      end
    end
  end

  describe "A3.4: structural witness over the current source (bounded)" do
    test "client.ex reads only the known environment variables and no other runtime config" do
      reads = runtime_reads(File.read!(@client_source))

      env = for {:env, name} <- reads, into: MapSet.new(), do: name
      other = Enum.reject(reads, &match?({:env, _}, &1))

      assert env == @known_env_reads,
             "System.get_env call sites in client.ex changed: #{inspect(MapSet.to_list(env))}"

      assert other == [], "client.ex gained a runtime-config read: #{inspect(other)}"
    end

    test "the release and ap wrappers forward argv and name no version outside comments" do
      for path <- [@release_wrapper, @ap_wrapper] do
        assert code_lines_mentioning(File.read!(path), "protocol") == [],
               "#{Path.basename(path)} must not select a protocol version"
      end

      release = File.read!(@release_wrapper)
      assert release =~ ~s|ARGV_B64="$(printf '%s\\0' "$@" \| base64 \| tr -d '\\n')"|

      ap = File.read!(@ap_wrapper)
      assert ap =~ ~s|ping\|reconcile\|sessions)\n    exec "$(resolve_bin ai-pair)" "$CMD" "$@"|
      assert ap =~ ~s|send)\n    resolve_project\n    exec "$(resolve_bin ai-pair)" send "$@"|
    end

    test "no config file names a protocol version" do
      paths = Path.wildcard(Path.join(@config_dir, "*.exs"))
      assert length(paths) >= 5, "config.exs, dev, prod, runtime and test are all read"

      for path <- paths do
        refute File.read!(path) =~ "protocol_version", "#{Path.basename(path)}"
      end
    end

    test "C3: the extractor reports an added environment or application-env read" do
      source = File.read!(@client_source)

      added_env = source <> "\ndefp x, do: System.get_env(\"AI_PAIR_X\")\n"
      assert {:env, "AI_PAIR_X"} in runtime_reads(added_env)

      added_app = source <> "\ndefp y, do: Application.get_env(:ai_pair, :protocol_version)\n"
      assert {:application, "get_env"} in runtime_reads(added_app)

      added_dynamic = source <> "\ndefp z(name), do: System.get_env(name)\n"

      assert {:env_dynamic, _} =
               Enum.find(runtime_reads(added_dynamic), &match?({:env_dynamic, _}, &1))

      added_term = source <> "\ndefp w, do: :persistent_term.get(:v)\n"
      assert {:persistent_term, "get"} in runtime_reads(added_term)
    end
  end

  # ===== daemon harness =====

  defp daemon(_context) do
    n = System.unique_integer([:positive])
    inbox = Path.join(System.tmp_dir!(), "ns42_c001_#{n}")
    File.mkdir_p!(Path.join(inbox, "sock"))
    File.chmod!(Path.join(inbox, "sock"), 0o700)
    on_exit(fn -> File.rm_rf!(inbox) end)

    store = start_supervised!({ReceiptStore, inbox: inbox})
    start_supervised!({Server, inbox: inbox, name: :"ns42_c001_server_#{n}", receipt_store: store})
    pastes = start_supervised!({Agent, fn -> 0 end})
    pane = "%ns42_c001_#{n}"

    {:ok, sm} =
      PaneSupervisor.start_pane(pane,
        receipt_store: store,
        capture_fn: fn _pane_id -> {:ok, "IDLE_MARKER"} end,
        paste_fn: fn _pane_id, _text -> Agent.update(pastes, &(&1 + 1)) end,
        classifier: MarkerClassifier,
        poll_interval_ms: 5,
        idle_debounce_ms: 0
      )

    on_exit(fn -> PaneSupervisor.stop_pane(pane) end)
    assert :ok = await_state(sm, :idle)

    {:ok,
     n: n,
     pane: pane,
     pastes: pastes,
     log: ReceiptStore.path(store),
     sock: Path.join(inbox, "sock/ai-pair.sock")}
  end

  defp frame(_c, "ping", _id), do: %{"cmd" => "ping", "protocol_version" => 2}

  defp frame(c, "send", id),
    do: %{
      "cmd" => "send",
      "protocol_version" => 2,
      "pane_id" => c.pane,
      "msg_id" => id,
      "text" => @text
    }

  defp frame(c, "reconcile", id),
    do: %{
      "cmd" => "reconcile",
      "protocol_version" => 2,
      "pane_id" => c.pane,
      "msg_id" => id,
      "payload_hash" => Payload.hash(Payload.new(@text)),
      "wait_ms" => 0
    }

  defp id(c, seed),
    do: "snd_" <> Base.encode16(:crypto.hash(:sha256, "#{seed}-#{c.n}"), case: :lower)

  defp pastes(c), do: Agent.get(c.pastes, & &1)

  defp send_frame!(sock, payload), do: send_raw!(sock, Jason.encode!(payload))

  defp send_raw!(sock, bytes) do
    {:ok, client} =
      :gen_tcp.connect({:local, sock}, 0, [:binary, {:active, false}, {:packet, 4}], 1_000)

    try do
      :ok = :gen_tcp.send(client, bytes)
      {:ok, frame} = :gen_tcp.recv(client, 0, 2_000)
      Jason.decode!(frame)
    after
      :gen_tcp.close(client)
    end
  end

  defp await_state(sm, target, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      cond do
        StateMachine.state(sm) == target -> :ok
        System.monotonic_time(:millisecond) > deadline -> {:timeout, StateMachine.state(sm)}
        true -> Process.sleep(5) && :retry
      end
    end)
    |> Enum.find(&(&1 != :retry))
  end

  # ===== CLI harness =====

  defp fake_daemon(_context) do
    root = Path.join(System.tmp_dir!(), "ns42_c001_cli_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    socket = Path.join(root, "c001.sock")
    previous = System.get_env("AI_PAIR_DAEMON_SOCK")
    System.put_env("AI_PAIR_DAEMON_SOCK", socket)

    on_exit(fn ->
      restore_env("AI_PAIR_DAEMON_SOCK", previous)
      File.rm_rf!(root)
    end)

    {:ok, socket: socket}
  end

  # Plausible ambient version sources: none of them is read by the client today.
  @ambient_env [
    {"AI_PAIR_PROTOCOL_VERSION", "1"},
    {"AI_PAIR_PROTOCOL", "1"},
    {"PROTOCOL_VERSION", "1"}
  ]

  defp with_ambient_overrides(fun) do
    previous_env = for {name, _} <- @ambient_env, do: {name, System.get_env(name)}
    previous_app = Application.fetch_env(:ai_pair, :protocol_version)

    on_exit(fn ->
      Enum.each(previous_env, fn {name, value} -> restore_env(name, value) end)
      restore_app(previous_app)
    end)

    Enum.each(@ambient_env, fn {name, value} -> System.put_env(name, value) end)
    Application.put_env(:ai_pair, :protocol_version, 1)

    try do
      fun.()
    after
      Enum.each(previous_env, fn {name, value} -> restore_env(name, value) end)
      restore_app(previous_app)
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp restore_app({:ok, value}), do: Application.put_env(:ai_pair, :protocol_version, value)
  defp restore_app(:error), do: Application.delete_env(:ai_pair, :protocol_version)

  defp versioned("ping"),
    do:
      {["ping", "--protocol-version", "2"],
       %{"ok" => true, "protocol_version" => 2, "capabilities" => ["delivery_reconcile"]}}

  defp versioned("send"),
    do:
      {["send", @cli_pane, "input", "--msg-id", @cli_id, "--protocol-version", "2"],
       bound_reply("status")}

  defp versioned("reconcile"),
    do:
      {[
         "reconcile",
         @cli_pane,
         "--msg-id",
         @cli_id,
         "--payload-hash",
         @cli_hash,
         "--protocol-version",
         "2"
       ], bound_reply("outcome")}

  defp bound_reply(key),
    do:
      %{"ok" => true, "protocol_version" => 2, "msg_id" => @cli_id, "pane_id" => @cli_pane}
      |> Map.put(key, "delivered")

  defp expected_keys("ping"), do: ~w(cmd protocol_version)
  defp expected_keys("send"), do: Enum.sort(~w(cmd msg_id pane_id protocol_version text))

  defp expected_keys("reconcile"),
    do: Enum.sort(~w(cmd msg_id pane_id payload_hash protocol_version wait_ms))

  # One accepted connection: returns the CLI's exit code and the request frame decoded
  # from the exact bytes the client sent.
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
      ref = make_ref()

      _stderr =
        capture_io(:stderr, fn ->
          _stdout = capture_io(fn -> send(self(), {ref, operation.()}) end)
        end)

      assert_receive {^ref, exit}
      {exit, Jason.decode!(Task.await(server, 2_000))}
    after
      :gen_tcp.close(listener)
      Task.shutdown(server, :brutal_kill)
      # A closed UNIX listener leaves its path behind; remove it so the next exchange in
      # the same test can bind it again.
      File.rm(socket)
    end
  end

  # ===== structural extractor =====

  # Every runtime-configuration read in `source`, as {kind, name}. A literal
  # `System.get_env("NAME")` is {:env, "NAME"}; any other `System.get_env(` form (a variable
  # argument, or the zero-arity whole-environment read) is {:env_dynamic, text}.
  defp runtime_reads(source) do
    code = strip_comments(source)

    literal_env = Regex.scan(~r/System\.get_env\(\s*"([^"]+)"\s*\)/, code)
    all_env = Regex.scan(~r/System\.get_env\(([^)]*)\)/, code)

    dynamic_env =
      for [_, arg] <- all_env, not Regex.match?(~r/\A\s*"[^"]+"\s*\z/, arg), do: {:env_dynamic, arg}

    others =
      [
        {~r/Application\.(get_env|fetch_env!?|compile_env!?|get_all_env)\b/, :application},
        {~r/:persistent_term\.(get|put)\b/, :persistent_term},
        {~r/System\.(fetch_env!?|get_env\(\s*\))/, :system},
        {~r/:os\.(getenv|env)\b/, :os},
        {~r/:init\.get_argument\b/, :init}
      ]
      |> Enum.flat_map(fn {regex, kind} ->
        for [_, name | _] <- Regex.scan(regex, code), do: {kind, name}
      end)

    Enum.map(literal_env, fn [_, name] -> {:env, name} end) ++ dynamic_env ++ others
  end

  # Drops `#` line comments and heredoc documentation so a mention in prose is not a read.
  defp strip_comments(source) do
    source
    |> String.replace(~r/"""[\s\S]*?"""/, "\"\"")
    |> String.split("\n")
    |> Enum.map(&Regex.replace(~r/^\s*#.*$/, &1, ""))
    |> Enum.join("\n")
  end

  defp code_lines_mentioning(source, word) do
    source
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
    |> Enum.filter(&String.contains?(String.downcase(&1), word))
  end
end
