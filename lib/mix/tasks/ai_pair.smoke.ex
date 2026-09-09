defmodule Mix.Tasks.AiPair.Smoke do
  @shortdoc "End-to-end smoke test: real TUI pane through PaneSupervisor + StateMachine"

  @moduledoc """
  Drives a real Claude Code or Codex CLI session through the actual
  `AiPair.PaneSupervisor` → `AiPair.Pane.StateMachine` path.

      mix ai_pair.smoke claude_code
      mix ai_pair.smoke codex_cli
      mix ai_pair.smoke synthetic_streaming
      mix ai_pair.smoke --all
      mix ai_pair.smoke claude_code --prompt "summarize the OTP supervision tree"

  ## Synthetic streaming recipe

  The `synthetic_streaming` recipe drives an in-tree shell loop that
  echoes its input then streams 5 tokens with sleeps. It uses an
  always-idle classifier so the StateMachine's content-stability gate
  is the only thing keeping a queued mid-stream send from firing.
  Verifies: first send → `:ok`; second send mid-stream → `{:queued, _}`,
  then drains in order. No external CLI required.

  ## What it exercises

    * Tmux session bootstrap and pane discovery via `AiPair.Tmux.list_panes/1`
    * Fingerprint-backed classifier via `AiPair.Pane.Classifier.Fingerprint.build/1`
    * `:gen_statem` per-pane state machine, including the content-stability
      gate (mid-stream output that fingerprints as `:idle` must not allow
      sends to fire while the TUI is still streaming).
    * Bracketed-paste delivery via `set-buffer` / `paste-buffer -p -r` /
      `send-keys Enter`.

  ## Assertions per run

    * After paste, the pane must transition into a non-idle state within
      `:busy_window_ms` — proves the classifier reacts to streaming output.
    * After the response settles, the StateMachine must stay `:idle` with
      `pending_count == 0` across `idle_debounce_ms + 500 ms` — the
      production invariant a real send relies on. (Byte-level pane
      stability cannot be asserted here: real TUIs like Claude Code
      2.1.133 repaint a dynamic status bar on a clock. The
      `synthetic_streaming` recipe owns gate-correctness.)

  Uses a dedicated tmux server (`-L ai-pair-smoke-<int>`) so the user's
  active tmux session is never touched. Does NOT start
  `AiPair.Application` (no IPC server, no Inbox dependency); only the
  Registry, PaneSupervisor, and a scoped `AiPair.Tmux` are booted.

  ## Environment overrides

    * `AI_PAIR_CAP_CLAUDE` — path to `claude`  (default `claude`)
    * `AI_PAIR_CAP_CODEX`  — path to `codex`   (default `codex`)
  """

  use Mix.Task

  alias AiPair.Fingerprint
  alias AiPair.Pane.Classifier
  alias AiPair.Pane.StateMachine
  alias AiPair.PaneSupervisor
  alias AiPair.Tmux

  @recipes %{
    "claude_code" => %{
      env_var: "AI_PAIR_CAP_CLAUDE",
      default_command: "claude",
      fingerprint: "priv/fingerprints/claude_code.json",
      idle_timeout_ms: 30_000,
      probe: "Reply with the single word OK and nothing else.",
      poll_interval_ms: 500,
      idle_debounce_ms: 1_000,
      busy_window_ms: 5_000
    },
    "codex_cli" => %{
      env_var: "AI_PAIR_CAP_CODEX",
      default_command: "codex",
      fingerprint: "priv/fingerprints/codex_cli.json",
      idle_timeout_ms: 30_000,
      probe: "Reply with the single word OK and nothing else.",
      poll_interval_ms: 500,
      idle_debounce_ms: 1_000,
      busy_window_ms: 5_000
    },
    "synthetic_streaming" => %{
      driver: :streaming,
      command: """
      while IFS= read -r line; do
        echo "received: $line"
        for i in 1 2 3 4 5; do
          printf '  token %d\\n' "$i"
          sleep 0.3
        done
      done
      """,
      poll_interval_ms: 200,
      idle_debounce_ms: 800,
      idle_timeout_ms: 5_000
    }
  }

  @impl Mix.Task
  def run(args) do
    {opts, positional} =
      OptionParser.parse!(args, strict: [all: :boolean, prompt: :string])

    Mix.Task.run("loadpaths")
    Mix.Task.run("app.config")

    tuis =
      cond do
        opts[:all] -> Map.keys(@recipes) |> Enum.sort()
        positional == [] -> Mix.raise(usage())
        true -> validate_tuis(positional)
      end

    prompt_override = opts[:prompt]

    socket = "ai-pair-smoke-#{System.unique_integer([:positive])}"
    Application.put_env(:ai_pair, :smoke_socket_name, socket)

    boot_runtime!(socket)

    try do
      results = Enum.map(tuis, &smoke_one(&1, socket, prompt_override))

      info("")
      info("== summary ==")

      Enum.each(results, fn {tui, ok?} ->
        info("  #{if ok?, do: "✓", else: "✗"} #{tui}")
      end)

      unless Enum.all?(results, fn {_, ok?} -> ok? end) do
        Mix.raise("one or more smoke tests failed")
      end
    after
      _ = run_tmux(socket, ["kill-server"])
    end
  end

  defp boot_runtime!(socket) do
    children = [
      {Registry, keys: :unique, name: AiPair.Registry},
      {AiPair.PaneSupervisor, []},
      %{
        id: AiPair.Tmux,
        start: {AiPair.Tmux, :start_link, [[name: AiPair.Tmux, socket_name: socket]]}
      }
    ]

    case Supervisor.start_link(children, strategy: :one_for_one, name: AiPair.SmokeSupervisor) do
      {:ok, _pid} -> :ok
      other -> Mix.raise("smoke runtime failed to start: #{inspect(other)}")
    end
  end

  defp usage do
    """
    Usage:
      mix ai_pair.smoke <tui> [--prompt "..."]
      mix ai_pair.smoke --all [--prompt "..."]

    Known TUIs: #{Enum.join(Map.keys(@recipes), ", ")}

    Options:
      --prompt <text>   Override the default probe text. Useful for testing
                        longer responses that exercise the streaming-output
                        path.
    """
  end

  defp validate_tuis(names) do
    Enum.each(names, fn n ->
      unless Map.has_key?(@recipes, n) do
        Mix.raise("Unknown TUI: #{n}\n\n#{usage()}")
      end
    end)

    names
  end

  defp smoke_one(tui, socket, prompt_override) do
    recipe_raw = Map.fetch!(@recipes, tui)

    case Map.get(recipe_raw, :driver, :standard) do
      :standard -> smoke_one_standard(tui, recipe_raw, socket, prompt_override)
      :streaming -> smoke_one_streaming(tui, recipe_raw, socket)
    end
  end

  defp smoke_one_standard(tui, recipe_base, socket, prompt_override) do
    recipe =
      case prompt_override do
        nil -> recipe_base
        text when is_binary(text) -> %{recipe_base | probe: text}
      end

    command = System.get_env(recipe.env_var, recipe.default_command)

    info("")
    info("== #{tui} ==")
    info("launching: #{command}  (override via $#{recipe.env_var})")

    ensure_command_exists!(command)
    fp = Fingerprint.load!(recipe.fingerprint)
    classifier = Classifier.Fingerprint.build(fp)

    session = "smoke-#{tui}-#{System.unique_integer([:positive])}"

    case bootstrap_session(socket, session, command) do
      {:ok, pane_id} ->
        try do
          smoke_drive(tui, pane_id, recipe, classifier)
        after
          _ = PaneSupervisor.stop_pane(pane_id)
          _ = run_tmux(socket, ["kill-session", "-t", session])
        end

      {:error, err} ->
        info("  ✗ failed to bootstrap session: #{inspect(err)}")
        {tui, false}
    end
  end

  defp smoke_one_streaming(tui, recipe, socket) do
    info("")
    info("== #{tui} ==")
    info("synthetic streaming TUI (always-idle classifier)")
    info("verifies the content-stability gate suppresses mid-stream paste")

    classifier = fn _stripped -> :idle end
    session = "smoke-#{tui}-#{System.unique_integer([:positive])}"

    case bootstrap_session(socket, session, recipe.command) do
      {:ok, pane_id} ->
        try do
          smoke_drive_streaming(tui, pane_id, recipe, classifier)
        after
          _ = PaneSupervisor.stop_pane(pane_id)
          _ = run_tmux(socket, ["kill-session", "-t", session])
        end

      {:error, err} ->
        info("  ✗ failed to bootstrap session: #{inspect(err)}")
        {tui, false}
    end
  end

  defp smoke_drive(tui, pane_id, recipe, classifier) do
    info("  pane_id=#{pane_id}")
    info("  starting StateMachine via PaneSupervisor...")

    case PaneSupervisor.start_pane(pane_id,
           classifier: classifier,
           poll_interval_ms: recipe.poll_interval_ms,
           idle_debounce_ms: recipe.idle_debounce_ms
         ) do
      {:ok, _pid} ->
        sm = PaneSupervisor.via_pane(pane_id)

        case wait_state(sm, :idle, recipe.idle_timeout_ms) do
          :ok ->
            info("  ✓ pane reached :idle")
            send_and_verify(tui, pane_id, sm, recipe)

          {:timeout, observed} ->
            info("  ✗ pane never reached :idle (last observed: #{observed})")
            dump_pane_for_debug(pane_id)
            {tui, false}
        end

      {:error, err} ->
        info("  ✗ start_pane failed: #{inspect(err)}")
        {tui, false}
    end
  end

  defp send_and_verify(tui, pane_id, sm, recipe) do
    info("  sending probe via StateMachine.send_text/3 (#{inspect(recipe.probe)})")

    case StateMachine.send_text(sm, recipe.probe) do
      :ok ->
        info("  ✓ send_text returned :ok (paste eligible immediately)")
        assert_response_cycle(tui, pane_id, sm, recipe)

      {:queued, reason} ->
        info("  send_text queued (reason=#{inspect(reason)}); waiting for drain...")

        # Allow time for the debounce + drain cycle to complete.
        Process.sleep(recipe.idle_debounce_ms + 500)

        if StateMachine.pending_count(sm) == 0 do
          info("  ✓ queue drained")
          assert_response_cycle(tui, pane_id, sm, recipe)
        else
          info("  ✗ queue did not drain within debounce window")
          {tui, false}
        end

      {:error, err} ->
        info("  ✗ send_text errored: #{inspect(err)}")
        {tui, false}
    end
  end

  defp assert_response_cycle(tui, pane_id, sm, recipe) do
    case wait_for_busy(sm, recipe.busy_window_ms) do
      {:ok, observed} ->
        info("  ✓ observed transition to #{inspect(observed)} (classifier sees streaming)")

        case wait_state(sm, :idle, recipe.idle_timeout_ms) do
          :ok ->
            info("  ✓ pane returned to :idle after response")

            stability_window_ms = recipe.idle_debounce_ms + 500

            case verify_sm_remains_idle(sm, stability_window_ms) do
              :ok ->
                info("  ✓ SM stayed :idle with 0 pending across #{stability_window_ms}ms")
                dump_pane_for_debug(pane_id)
                {tui, true}

              {:error, reason} ->
                info("  ✗ SM stability assertion failed: #{inspect(reason)}")
                dump_pane_for_debug(pane_id)
                {tui, false}
            end

          {:timeout, observed_after} ->
            info("  ✗ pane never returned to :idle (last observed: #{observed_after})")
            dump_pane_for_debug(pane_id)
            {tui, false}
        end

      :timeout ->
        info(
          "  ✗ never observed :busy/:dialog within " <>
            "#{recipe.busy_window_ms}ms — classifier may have missed streaming, " <>
            "or the response was too fast to observe"
        )

        dump_pane_for_debug(pane_id)
        {tui, false}
    end
  end

  defp smoke_drive_streaming(tui, pane_id, recipe, classifier) do
    info("  pane_id=#{pane_id}")
    info("  starting StateMachine via PaneSupervisor (always-idle classifier)...")

    case PaneSupervisor.start_pane(pane_id,
           classifier: classifier,
           poll_interval_ms: recipe.poll_interval_ms,
           idle_debounce_ms: recipe.idle_debounce_ms
         ) do
      {:ok, _pid} ->
        sm = PaneSupervisor.via_pane(pane_id)

        case wait_state(sm, :idle, recipe.idle_timeout_ms) do
          :ok ->
            info("  ✓ pane reached :idle")
            run_streaming_assertions(tui, pane_id, sm, recipe)

          {:timeout, observed} ->
            info("  ✗ pane never reached :idle (last=#{observed})")
            dump_pane_for_debug(pane_id)
            {tui, false}
        end

      {:error, err} ->
        info("  ✗ start_pane failed: #{inspect(err)}")
        {tui, false}
    end
  end

  defp run_streaming_assertions(tui, pane_id, sm, recipe) do
    # Wait long enough for the initial idle/stable settle (no streaming yet,
    # the bash loop is blocked on `read`).
    Process.sleep(recipe.idle_debounce_ms + 200)

    info("  sending first probe (expect :ok — pane idle and stable)")

    case StateMachine.send_text(sm, "first") do
      :ok ->
        info("  ✓ first send returned :ok")

        # Allow at least one poll cycle so the SM observes streaming output
        # and rearms the debounce window.
        Process.sleep(recipe.poll_interval_ms * 2)

        info("  sending second probe mid-stream (expect {:queued, _})")

        case StateMachine.send_text(sm, "second") do
          {:queued, reason} ->
            info("  ✓ second send queued (reason=#{inspect(reason)}) — gate working")
            await_drain_and_verify(tui, pane_id, sm, recipe)

          :ok ->
            info("  ✗ second send returned :ok — content-stability gate did NOT")
            info("       suppress a mid-stream paste. This is the bug we're guarding.")
            dump_pane_for_debug(pane_id)
            {tui, false}

          {:error, err} ->
            info("  ✗ second send errored: #{inspect(err)}")
            {tui, false}
        end

      {:queued, reason} ->
        info("  ✗ first send was unexpectedly queued (reason=#{inspect(reason)})")
        {tui, false}

      {:error, err} ->
        info("  ✗ first send errored: #{inspect(err)}")
        {tui, false}
    end
  end

  defp await_drain_and_verify(tui, pane_id, sm, recipe) do
    # Streaming responder emits 5 tokens at 0.3s each = ~1.5s per prompt.
    # After the first response ends, idle_debounce_ms must elapse with stable
    # content before the queued "second" drains. Then "second" itself streams
    # ~1.5s plus another debounce window before things finally settle.
    stream_ms = 1_500
    total_ms = stream_ms + recipe.idle_debounce_ms + stream_ms + recipe.idle_debounce_ms + 1_000
    info("  waiting #{total_ms}ms for both responses to drain and settle...")
    Process.sleep(total_ms)

    pending = StateMachine.pending_count(sm)

    if pending == 0 do
      info("  ✓ queue drained")

      case verify_streaming_outputs(pane_id) do
        :ok ->
          info("  ✓ both prompts processed in order")
          dump_pane_for_debug(pane_id)
          {tui, true}

        {:error, reason} ->
          info("  ✗ output verification failed: #{inspect(reason)}")
          dump_pane_for_debug(pane_id)
          {tui, false}
      end
    else
      info("  ✗ queue did not drain (#{pending} pending)")
      dump_pane_for_debug(pane_id)
      {tui, false}
    end
  end

  defp verify_streaming_outputs(pane_id) do
    case Tmux.capture_pane(pane_id) do
      {:ok, raw} ->
        stripped = strip_ansi(raw)
        first_idx = :binary.match(stripped, "received: first")
        second_idx = :binary.match(stripped, "received: second")

        cond do
          first_idx == :nomatch -> {:error, :first_response_not_found}
          second_idx == :nomatch -> {:error, :second_response_not_found}
          elem(first_idx, 0) >= elem(second_idx, 0) -> {:error, :out_of_order}
          true -> :ok
        end

      {:error, err} ->
        {:error, {:capture_failed, err}}
    end
  end

  defp wait_for_busy(sm, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_for_busy(sm, deadline)
  end

  defp poll_for_busy(sm, deadline) do
    observed =
      try do
        StateMachine.state(sm)
      catch
        :exit, _ -> :unknown
      end

    cond do
      observed in [:busy, :dialog] ->
        {:ok, observed}

      System.monotonic_time(:millisecond) > deadline ->
        :timeout

      true ->
        Process.sleep(50)
        poll_for_busy(sm, deadline)
    end
  end

  # Invariant: after a response settles, the SM remains :idle with
  # an empty queue across the stability window. Byte-level pane stability
  # cannot be asserted on real TUIs — Claude Code 2.1.133's bottom status
  # bar (✻ spinner, ctx:N%, weekly-limit countdown) repaints on a clock,
  # so the synthetic recipe owns gate-correctness and this check owns the
  # production invariant.
  defp verify_sm_remains_idle(sm, window_ms) do
    deadline = System.monotonic_time(:millisecond) + window_ms
    do_verify_sm_remains_idle(sm, deadline)
  end

  defp do_verify_sm_remains_idle(sm, deadline) do
    state =
      try do
        StateMachine.state(sm)
      catch
        :exit, reason -> {:exit, reason}
      end

    pending =
      try do
        StateMachine.pending_count(sm)
      catch
        :exit, reason -> {:exit, reason}
      end

    cond do
      match?({:exit, _}, state) ->
        {:error, {:sm_call_failed, state}}

      match?({:exit, _}, pending) ->
        {:error, {:sm_call_failed, pending}}

      state != :idle ->
        {:error, {:state_drifted, state}}

      pending != 0 ->
        {:error, {:pending_nonzero, pending}}

      System.monotonic_time(:millisecond) >= deadline ->
        :ok

      true ->
        Process.sleep(100)
        do_verify_sm_remains_idle(sm, deadline)
    end
  end

  defp wait_state(sm, target, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_state(sm, target, deadline, :unknown)
  end

  defp do_wait_state(sm, target, deadline, _last) do
    observed =
      try do
        StateMachine.state(sm)
      catch
        :exit, _ -> :unknown
      end

    cond do
      observed == target ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        {:timeout, observed}

      true ->
        Process.sleep(250)
        do_wait_state(sm, target, deadline, observed)
    end
  end

  defp dump_pane_for_debug(pane_id) do
    case Tmux.capture_pane(pane_id) do
      {:ok, raw} ->
        info("  --- pane snapshot (last 16 non-blank lines, ANSI-stripped) ---")

        raw
        |> strip_ansi()
        |> String.split(~r/\r?\n/)
        |> Enum.reject(&(String.trim(&1) == ""))
        |> Enum.take(-16)
        |> Enum.each(fn line -> info("    | #{line}") end)

        info("  --- end snapshot ---")

      {:error, err} ->
        info("  (could not capture pane for debug: #{inspect(err)})")
    end
  end

  defp ensure_command_exists!(command) do
    bin = command |> String.split(" ", parts: 2) |> hd()

    if System.find_executable(bin) == nil do
      Mix.raise("""
      Cannot find executable: #{bin}

      Set the override env var if your binary lives elsewhere.
      """)
    end
  end

  defp bootstrap_session(socket, session, command) do
    case run_tmux(socket, [
           "new-session",
           "-d",
           "-s",
           session,
           "-x",
           "120",
           "-y",
           "40",
           "--",
           "sh",
           "-c",
           command
         ]) do
      {:ok, _} -> find_pane(session)
      {:error, _} = err -> err
    end
  end

  defp find_pane(session) do
    case Tmux.list_panes() do
      {:ok, panes} ->
        case Enum.find(panes, fn p -> p.session == session end) do
          nil -> {:error, :pane_not_found}
          pane -> {:ok, pane.id}
        end

      {:error, _} = err ->
        err
    end
  end

  defp run_tmux(socket, args) do
    full = ["-L", socket | args]

    case System.cmd("tmux", full, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, status} -> {:error, %{cmd: ["tmux" | full], status: status, stderr: out}}
    end
  end

  defp strip_ansi(binary) do
    Regex.replace(~r/\e\[[0-9;?]*[ -\/]*[@-~]/, binary, "")
  end

  defp info(msg), do: Mix.shell().info(msg)
end
