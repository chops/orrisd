defmodule AiPair.Calibrator do
  @moduledoc """
  TUI fingerprint calibrator: spawns a TUI in a dedicated tmux server,
  drives it through idle and busy states, captures `tmux capture-pane`
  frames to fixture files, and verifies each capture against the
  configured fingerprint JSON.

  Runtime entry point — has no Mix dependency, so it can be invoked
  from a release wrapper (`bin/ai-pair-calibrate`) via `release eval`.
  The Mix task `Mix.Tasks.AiPair.CaptureFingerprint` is now a thin shim
  that delegates to `main/1`.

  ## Public API

    * `main/1` — argv-driven CLI entry, returns POSIX-style exit status.
    * `capture/2` and `verify/2` — programmatic entries.
    * `known_tuis/0`, `recipe/1` — introspection.

  ## Options

  Both `capture/2` and `verify/2` accept:

    * `:log_fn`  — `(String.t() -> any())`, default `&IO.puts/1`
    * `:fixture_root` — fixture directory. Default in dev: `"test/fixtures/fingerprints"`.
      Default under a release: `$AI_PAIR_INBOX/fingerprints/captures`.
    * `:fingerprint_root` — fingerprint JSON directory. Defaults to
      `:code.priv_dir(:ai_pair)/fingerprints`, which resolves correctly
      both in the source tree (via Mix's priv symlink) and inside a
      release (`<release>/lib/ai_pair-<vsn>/priv`).
  """

  require OpenTelemetry.Tracer, as: Tracer

  alias AiPair.Tmux
  alias AiPair.Fingerprint

  @tmux_module AiPair.Tmux.Cap

  @recipes %{
    "claude_code" => %{
      env_var: "AI_PAIR_CAP_CLAUDE",
      default_command: "claude",
      idle_stable_ticks: 4,
      idle_poll_ms: 500,
      idle_timeout_ms: 20_000,
      idle_min_nonblank_lines: 3,
      prompt: """
      Without using any tools, browser, or file edits, write a detailed \
      explanation (at least 400 words, taking your time and streaming \
      tokens slowly) of how Erlang/OTP `:gen_statem` differs from \
      `:gen_server`, including state-enter callbacks, timeouts, and a \
      worked example of a debounced input handler.
      """,
      busy_diverge_timeout_ms: 8_000,
      busy_settle_ms: 1_500,
      busy_frames: 5,
      busy_interval_ms: 1_000
    },
    "codex_cli" => %{
      env_var: "AI_PAIR_CAP_CODEX",
      default_command: "codex",
      idle_stable_ticks: 4,
      idle_poll_ms: 500,
      idle_timeout_ms: 20_000,
      idle_min_nonblank_lines: 3,
      prompt: """
      Answer from general knowledge only. Do not use any tools, do not \
      read any files, do not run any shell commands, do not browse the \
      web. In at least 500 words of streamed prose, explain the \
      conceptual difference between Erlang/OTP `:gen_statem` and \
      `:gen_server`, covering state-enter callbacks, `:state_timeout`, \
      and when you would reach for one over the other. Take your time.
      """,
      busy_diverge_timeout_ms: 8_000,
      busy_settle_ms: 1_500,
      busy_frames: 5,
      busy_interval_ms: 1_000
    }
  }

  @type log_fn :: (String.t() -> any())
  @type opts :: [
          log_fn: log_fn(),
          fixture_root: String.t(),
          fingerprint_root: String.t()
        ]

  # ===== Introspection =====

  @spec known_tuis() :: [String.t()]
  def known_tuis, do: Map.keys(@recipes) |> Enum.sort()

  @spec recipe(String.t()) :: {:ok, map()} | :error
  def recipe(tui), do: Map.fetch(@recipes, tui)

  # ===== CLI entry =====

  @doc """
  Argv-driven entry. Returns a POSIX-style exit status:

    * `0` — success
    * `1` — runtime failure (capture / verify hit a hard error)
    * `2` — usage error (bad args)

  Recognized invocations:

      ai-pair-calibrate <tui>
      ai-pair-calibrate --all
      ai-pair-calibrate --verify-only <tui>
      ai-pair-calibrate --verify-only --all
      ai-pair-calibrate --verify-only --strict --all   # mismatch ⇒ exit 1

  By default, fingerprint mismatches in `--verify-only` mode print but
  do not fail (matching the existing developer workflow). Pass
  `--strict` to escalate mismatches to exit 1.
  """
  @spec main([String.t()]) :: 0 | 1 | 2
  def main(argv) when is_list(argv) do
    case parse_argv(argv) do
      {:ok, :capture, tuis, opts} -> exit_status(capture(tuis, opts))
      {:ok, :verify, tuis, opts} -> exit_status(verify(tuis, opts))
      {:error, msg} -> usage_error(msg)
    end
  end

  @doc """
  Release-wrapper entry. Decodes argv from `AI_PAIR_ARGV_B64`
  (NUL-delimited, base64-encoded — `release eval CODE` does not
  populate `System.argv/0`), runs `main/1`, and halts the BEAM
  with the resulting exit code.
  """
  @spec main_from_env() :: no_return()
  def main_from_env do
    AiPair.CLI.Client.ensure_otel_started_for_eval()

    exit_code = main(AiPair.CLI.Client.argv())

    # With the eval-local `:simple` processor, ended calibrator spans
    # have already been exported before `main/1` returns. Keep the
    # provider flush for custom/already-started SDK configurations.
    try do
      :otel_tracer_provider.force_flush()
    catch
      _, _ -> :ok
    end

    System.halt(exit_code)
  end

  defp exit_status(:ok), do: 0
  defp exit_status({:ok, _}), do: 0
  defp exit_status({:error, _}), do: 1

  defp usage_error(msg) do
    IO.puts(:stderr, msg)
    IO.puts(:stderr, "")
    IO.puts(:stderr, usage())
    2
  end

  defp usage do
    """
    Usage:
      ai-pair-calibrate <tui>
      ai-pair-calibrate --all
      ai-pair-calibrate --verify-only <tui>

    Known TUIs: #{Enum.join(known_tuis(), ", ")}
    """
  end

  defp parse_argv(argv) do
    {opts, positional} =
      OptionParser.parse!(argv,
        strict: [all: :boolean, verify_only: :boolean, strict: :boolean]
      )

    mode = if opts[:verify_only], do: :verify, else: :capture
    forwarded = if opts[:strict], do: [strict: true], else: []

    cond do
      opts[:all] ->
        {:ok, mode, known_tuis(), forwarded}

      positional == [] ->
        {:error, "no TUI specified"}

      true ->
        case validate_tuis(positional) do
          :ok -> {:ok, mode, positional, forwarded}
          {:error, _} = err -> err
        end
    end
  rescue
    e in OptionParser.ParseError -> {:error, "bad arguments: #{Exception.message(e)}"}
  end

  defp validate_tuis(names) do
    unknown = Enum.reject(names, &Map.has_key?(@recipes, &1))

    if unknown == [] do
      :ok
    else
      {:error, "unknown TUIs: #{Enum.join(unknown, ", ")}"}
    end
  end

  # ===== Programmatic entries =====

  @doc """
  Runs the full capture flow for each TUI: idle stabilize → snapshot
  idle frame → paste prompt → wait for divergence → snapshot N busy
  frames. Verifies the resulting fixtures against the fingerprint JSON.

  Returns `:ok` only if every TUI succeeded; `{:error, {:failures, list}}`
  otherwise. The list contains `{tui, reason}` entries.
  """
  @spec capture([String.t()], opts) :: :ok | {:error, term()}
  def capture(tuis, opts \\ []) when is_list(tuis) do
    Tracer.with_span "calibrator.capture",
      attributes: %{
        "calibrator.tui_count" => length(tuis),
        "calibrator.tuis" => Enum.join(tuis, ",")
      } do
      log = Keyword.get(opts, :log_fn, &default_log/1)
      fixture_root = Keyword.get(opts, :fixture_root, default_fixture_root())
      fingerprint_root = Keyword.get(opts, :fingerprint_root, default_fingerprint_root())

      case validate_tuis(tuis) do
        :ok ->
          socket = "ai-pair-cap-#{System.unique_integer([:positive])}"

          case start_tmux(socket) do
            {:ok, tmux_pid, owned?} ->
              try do
                failures =
                  Enum.flat_map(tuis, fn tui ->
                    case capture_for_tui(tui, socket, log, fixture_root, fingerprint_root) do
                      :ok -> []
                      {:error, reason} -> [{tui, reason}]
                    end
                  end)

                if failures == [] do
                  :ok
                else
                  Tracer.set_attribute("calibrator.error_reason", "tui_failures")
                  Tracer.set_attribute("calibrator.failure_count", length(failures))
                  Tracer.set_status(:error, "tui_failures")
                  {:error, {:failures, failures}}
                end
              after
                _ = run_tmux_socket(socket, ["kill-server"])
                if owned?, do: stop_tmux(tmux_pid)
              end

            {:error, reason} ->
              Tracer.set_attribute("calibrator.error_reason", "tmux_start_failed")
              Tracer.set_status(:error, "tmux_start_failed: #{inspect(reason)}")
              {:error, {:tmux_start_failed, reason}}
          end

        {:error, _} = err ->
          Tracer.set_attribute("calibrator.error_reason", "unknown_tui")
          Tracer.set_status(:error, "unknown_tui")
          err
      end
    end
  end

  @doc """
  Runs verify-only on each TUI: globs `<fixture_root>/<tui>/*.txt` and
  matches each capture against the fingerprint JSON.

  Default behavior (lenient): mismatches print but do not fail. Returns
  `{:ok, %{passed: N, mismatched: list}}` so callers can inspect.

  Pass `strict: true` to escalate mismatches to `{:error, ...}`.

  Hard errors (missing fingerprint file, unreadable fixture) always fail.
  """
  @spec verify([String.t()], opts) :: {:ok, map()} | {:error, term()}
  def verify(tuis, opts \\ []) when is_list(tuis) do
    Tracer.with_span "calibrator.verify",
      attributes: %{
        "calibrator.tui_count" => length(tuis),
        "calibrator.tuis" => Enum.join(tuis, ",")
      } do
      log = Keyword.get(opts, :log_fn, &default_log/1)
      fixture_root = Keyword.get(opts, :fixture_root, default_fixture_root())
      fingerprint_root = Keyword.get(opts, :fingerprint_root, default_fingerprint_root())
      strict? = Keyword.get(opts, :strict, false)
      Tracer.set_attribute("calibrator.strict", strict?)

      case validate_tuis(tuis) do
        :ok ->
          results =
            Enum.map(tuis, fn tui ->
              {tui, verify_fixtures(tui, log, fixture_root, fingerprint_root)}
            end)

          hard_errors =
            Enum.flat_map(results, fn
              {tui, {:error, reason}} when not is_tuple(reason) -> [{tui, reason}]
              {tui, {:error, {:io, _} = e}} -> [{tui, e}]
              {tui, {:error, {:fingerprint_load, _} = e}} -> [{tui, e}]
              _ -> []
            end)

          mismatches =
            Enum.flat_map(results, fn
              {tui, {:ok, %{mismatched: m}}} when m != [] -> [{tui, m}]
              _ -> []
            end)

          passed =
            results
            |> Enum.map(fn
              {_tui, {:ok, %{passed: p}}} -> p
              _ -> 0
            end)
            |> Enum.sum()

          Tracer.set_attribute("calibrator.passed", passed)
          Tracer.set_attribute("calibrator.mismatch_count", length(mismatches))

          cond do
            hard_errors != [] ->
              Tracer.set_attribute("calibrator.error_reason", "hard_errors")
              Tracer.set_status(:error, "hard_errors")
              {:error, {:hard_errors, hard_errors}}

            strict? and mismatches != [] ->
              Tracer.set_attribute("calibrator.error_reason", "mismatches")
              Tracer.set_status(:error, "mismatches")
              {:error, {:mismatches, mismatches}}

            true ->
              {:ok, %{passed: passed, mismatched: mismatches}}
          end

        {:error, _} = err ->
          Tracer.set_attribute("calibrator.error_reason", "unknown_tui")
          Tracer.set_status(:error, "unknown_tui")
          err
      end
    end
  end

  # ===== Tmux lifecycle =====

  defp start_tmux(socket) do
    case Tmux.start_link(socket_name: socket, name: @tmux_module) do
      {:ok, pid} -> {:ok, pid, true}
      {:error, {:already_started, pid}} -> {:ok, pid, false}
      {:error, _} = err -> err
    end
  end

  defp stop_tmux(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end
  end

  # ===== Capture (per-TUI) =====

  defp capture_for_tui(tui, socket, log, fixture_root, fingerprint_root) do
    Tracer.with_span "calibrator.tui", attributes: %{"calibrator.tui" => tui} do
      recipe = Map.fetch!(@recipes, tui)
      command = System.get_env(recipe.env_var, recipe.default_command)
      Tracer.set_attribute("calibrator.command", command)

      log.("== #{tui} ==")
      log.("launching: #{command}  (override via $#{recipe.env_var})")

      with :ok <- ensure_command_exists(command),
           {:ok, pane_id, session} <- bootstrap_session(socket, command),
           capture_result <- drive_and_capture(tui, pane_id, recipe, log, fixture_root) do
        _ = run_tmux_socket(socket, ["kill-session", "-t", session])

        case capture_result do
          :ok ->
            case verify_fixtures(tui, log, fixture_root, fingerprint_root) do
              {:ok, _} ->
                :ok

              {:error, reason} = err ->
                Tracer.set_attribute("calibrator.error_reason", "verify_failed")
                Tracer.set_status(:error, "verify_failed: #{inspect(reason)}")
                err
            end

          {:error, reason} = err ->
            Tracer.set_attribute("calibrator.error_reason", "capture_failed")
            Tracer.set_status(:error, "capture_failed: #{inspect(reason)}")
            err
        end
      else
        {:error, reason} = err ->
          log.("  ✗ #{format_reason(reason)}")
          Tracer.set_attribute("calibrator.error_reason", error_reason_label(reason))
          Tracer.set_status(:error, format_reason(reason))
          err
      end
    end
  end

  defp error_reason_label({:command_not_found, _}), do: "command_not_found"
  defp error_reason_label(:pane_not_found), do: "pane_not_found"
  defp error_reason_label(%{cmd: _, status: _}), do: "tmux_command_failed"
  defp error_reason_label(_), do: "unknown"

  defp drive_and_capture(tui, pane_id, recipe, log, fixture_root) do
    log.(
      "  waiting for idle (stable for #{recipe.idle_stable_ticks} ticks @ #{recipe.idle_poll_ms}ms, ≥#{recipe.idle_min_nonblank_lines} non-blank lines)..."
    )

    with {:ok, idle_baseline} <-
           wait_for_stable_capture(
             pane_id,
             recipe.idle_stable_ticks,
             recipe.idle_poll_ms,
             recipe.idle_timeout_ms,
             recipe.idle_min_nonblank_lines
           ),
         :ok <- capture_frame(tui, pane_id, "idle", log, fixture_root),
         _ = log.("  pasting prompt..."),
         :ok <- paste_prompt(pane_id, recipe.prompt),
         :ok <- wait_for_divergence(pane_id, idle_baseline, recipe.busy_diverge_timeout_ms) do
      Process.sleep(recipe.busy_settle_ms)

      Enum.reduce_while(1..recipe.busy_frames, :ok, fn n, _acc ->
        case capture_frame(tui, pane_id, "busy", log, fixture_root) do
          :ok ->
            if n < recipe.busy_frames, do: Process.sleep(recipe.busy_interval_ms)
            {:cont, :ok}

          {:error, _} = err ->
            {:halt, err}
        end
      end)
    else
      {:error, :idle_timeout} ->
        log.("  ✗ idle never stabilized within #{recipe.idle_timeout_ms}ms")
        {:error, :idle_timeout}

      {:error, :diverge_timeout} ->
        log.("  ✗ never diverged from idle baseline within #{recipe.busy_diverge_timeout_ms}ms")
        {:error, :diverge_timeout}

      {:error, reason} = err ->
        log.("  ✗ capture pipeline failed: #{format_reason(reason)}")
        err
    end
  end

  defp wait_for_stable_capture(pane_id, ticks_required, poll_ms, timeout_ms, min_nonblank_lines) do
    Tracer.with_span "calibrator.wait_idle",
      attributes: %{
        "calibrator.pane_id" => pane_id,
        "calibrator.idle_stable_ticks" => ticks_required,
        "calibrator.idle_poll_ms" => poll_ms,
        "calibrator.idle_timeout_ms" => timeout_ms,
        "calibrator.idle_min_nonblank_lines" => min_nonblank_lines
      } do
      deadline = System.monotonic_time(:millisecond) + timeout_ms

      case do_wait_stable(pane_id, ticks_required, poll_ms, deadline, min_nonblank_lines, nil, 0) do
        {:ok, _} = ok ->
          ok

        {:error, :idle_timeout} = err ->
          Tracer.set_attribute("calibrator.error_reason", "idle_timeout")
          Tracer.set_status(:error, "idle_timeout")
          err
      end
    end
  end

  defp do_wait_stable(pane_id, ticks_required, poll_ms, deadline, min_nonblank, last, count) do
    cond do
      count >= ticks_required and is_binary(last) and
          nonblank_count(strip_ansi(last)) >= min_nonblank ->
        {:ok, last}

      System.monotonic_time(:millisecond) > deadline ->
        {:error, :idle_timeout}

      true ->
        {next_last, next_count} =
          case Tmux.capture_pane(pane_id, [], @tmux_module) do
            {:ok, raw} ->
              stripped = strip_ansi(raw)

              if last != nil and stripped == strip_ansi(last) do
                {last, count + 1}
              else
                {raw, 1}
              end

            {:error, _} ->
              {last, count}
          end

        Process.sleep(poll_ms)

        do_wait_stable(
          pane_id,
          ticks_required,
          poll_ms,
          deadline,
          min_nonblank,
          next_last,
          next_count
        )
    end
  end

  defp wait_for_divergence(pane_id, baseline, timeout_ms) do
    Tracer.with_span "calibrator.wait_diverge",
      attributes: %{
        "calibrator.pane_id" => pane_id,
        "calibrator.diverge_timeout_ms" => timeout_ms
      } do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      baseline_stripped = strip_ansi(baseline)

      case do_wait_diverge(pane_id, baseline_stripped, deadline) do
        :ok ->
          :ok

        {:error, :diverge_timeout} = err ->
          Tracer.set_attribute("calibrator.error_reason", "diverge_timeout")
          Tracer.set_status(:error, "diverge_timeout")
          err
      end
    end
  end

  defp do_wait_diverge(pane_id, baseline_stripped, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :diverge_timeout}
    else
      case Tmux.capture_pane(pane_id, [], @tmux_module) do
        {:ok, raw} ->
          if strip_ansi(raw) != baseline_stripped do
            :ok
          else
            Process.sleep(250)
            do_wait_diverge(pane_id, baseline_stripped, deadline)
          end

        {:error, _} ->
          Process.sleep(250)
          do_wait_diverge(pane_id, baseline_stripped, deadline)
      end
    end
  end

  defp ensure_command_exists(command) do
    bin = command |> String.split(" ", parts: 2) |> hd()

    if System.find_executable(bin) do
      :ok
    else
      {:error, {:command_not_found, bin}}
    end
  end

  defp bootstrap_session(socket, command) do
    session = "cap-#{System.unique_integer([:positive])}"

    case run_tmux_socket(socket, [
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
      {:ok, _} ->
        case find_pane_in_session(session) do
          {:ok, pane_id} -> {:ok, pane_id, session}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  defp find_pane_in_session(session) do
    case Tmux.list_panes(@tmux_module) do
      {:ok, panes} ->
        case Enum.find(panes, fn p -> p.session == session end) do
          nil -> {:error, :pane_not_found}
          pane -> {:ok, pane.id}
        end

      {:error, _} = err ->
        err
    end
  end

  defp paste_prompt(pane_id, text) do
    buf = "ai_pair_cap_#{System.unique_integer([:positive])}"

    with :ok <- Tmux.set_buffer(buf, text, @tmux_module),
         :ok <- Tmux.paste_buffer(pane_id, buf, [delete: true], @tmux_module),
         :ok <- Tmux.send_keys(pane_id, ["Enter"], @tmux_module) do
      :ok
    end
  end

  defp capture_frame(tui, pane_id, state, log, fixture_root) do
    case Tmux.capture_pane(pane_id, [], @tmux_module) do
      {:ok, raw} ->
        path = fixture_path(fixture_root, tui, state, next_index(fixture_root, tui, state))
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, raw)
        log.("  captured #{path} (#{byte_size(raw)} bytes)")
        :ok

      {:error, reason} = err ->
        log.("  ✗ capture failed: #{format_reason(reason)}")
        err
    end
  end

  defp next_index(fixture_root, tui, state) do
    glob =
      [fixture_root, tui]
      |> Path.join()
      |> Path.join("#{state}_*.txt")

    nums =
      glob
      |> Path.wildcard()
      |> Enum.map(fn path ->
        case Regex.run(~r/_(\d+)\.txt$/, Path.basename(path)) do
          [_, num] -> String.to_integer(num)
          _ -> 0
        end
      end)

    case nums do
      [] -> 1
      _ -> Enum.max(nums) + 1
    end
  end

  defp fixture_path(fixture_root, tui, state, idx) do
    suffix = String.pad_leading(to_string(idx), 3, "0")
    Path.join([fixture_root, tui, "#{state}_#{suffix}.txt"])
  end

  # ===== Verify =====

  defp verify_fixtures(tui, log, fixture_root, fingerprint_root) do
    fp_path = Path.join(fingerprint_root, "#{tui}.json")

    Tracer.with_span "calibrator.verify_fixtures",
      attributes: %{
        "calibrator.tui" => tui,
        "calibrator.fingerprint_path" => fp_path,
        "calibrator.fixture_root" => fixture_root
      } do
      log.("verifying #{tui} fixtures against #{fp_path}")

      case load_fingerprint(fp_path) do
        {:ok, fp} ->
          fixtures =
            [fixture_root, tui]
            |> Path.join()
            |> Path.join("*.txt")
            |> Path.wildcard()
            |> Enum.sort()

          case fixtures do
            [] ->
              Tracer.set_attribute("calibrator.fixture_count", 0)
              log.("  (no fixtures found in #{Path.join(fixture_root, tui)})")
              {:ok, %{passed: 0, mismatched: []}}

            _ ->
              Tracer.set_attribute("calibrator.fixture_count", length(fixtures))

              {passed, mismatched} =
                Enum.reduce(fixtures, {0, []}, fn path, {ok_count, miss} ->
                  basename = Path.basename(path, ".txt")
                  expected = state_from_basename(basename)
                  raw = File.read!(path)

                  actual =
                    case Fingerprint.match(raw, fp) do
                      {:ok, state} -> state
                      {:error, :no_match} -> :no_match
                    end

                  if actual == expected do
                    log.("  ✓ #{basename}: expected=#{expected} actual=#{actual}")
                    {ok_count + 1, miss}
                  else
                    log.("  ✗ #{basename}: expected=#{expected} actual=#{actual}")
                    dump_bottom_lines(raw, fp, expected, log)
                    {ok_count, [{basename, expected, actual} | miss]}
                  end
                end)

              Tracer.set_attribute("calibrator.passed", passed)
              Tracer.set_attribute("calibrator.mismatch_count", length(mismatched))

              {:ok, %{passed: passed, mismatched: Enum.reverse(mismatched)}}
          end

        {:error, reason} ->
          log.("  ✗ could not load fingerprint at #{fp_path}: #{format_reason(reason)}")
          Tracer.set_attribute("calibrator.error_reason", "fingerprint_load")
          Tracer.set_status(:error, "fingerprint_load: #{inspect(reason)}")
          {:error, {:fingerprint_load, reason}}
      end
    end
  end

  defp load_fingerprint(path) do
    try do
      {:ok, Fingerprint.load!(path)}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp dump_bottom_lines(raw, fp, expected_state, log) do
    n = bottom_lines_for(fp, expected_state) || 10
    stripped = strip_ansi(raw)

    lines =
      stripped
      |> String.split(~r/\r?\n/)
      |> Enum.reverse()
      |> Enum.drop_while(&(String.trim(&1) == ""))
      |> Enum.take(n)
      |> Enum.reverse()

    Enum.each(lines, fn line -> log.("      | #{line}") end)
  end

  defp bottom_lines_for(fp, state) do
    case fp do
      %{"states" => states} ->
        case Map.get(states, to_string(state)) do
          %{"bottom_lines" => n} when is_integer(n) -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp state_from_basename(basename) do
    case String.split(basename, "_", parts: 2) do
      [state, _] -> String.to_atom(state)
      _ -> :unknown
    end
  end

  # ===== Helpers =====

  defp nonblank_count(stripped) do
    stripped
    |> String.split(~r/\r?\n/)
    |> Enum.count(fn line -> String.trim(line) != "" end)
  end

  defp strip_ansi(binary) do
    Regex.replace(~r/\e\[[0-9;?]*[ -\/]*[@-~]/, binary, "")
  end

  defp run_tmux_socket(socket, args) do
    full = ["-L", socket | args]

    case System.cmd("tmux", full, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, %{cmd: ["tmux" | full], status: status, stderr: output}}
    end
  end

  defp default_log(msg), do: IO.puts(msg)

  # Released apps live at <release>/lib/ai_pair-<vsn>/priv; in dev,
  # `:code.priv_dir/1` resolves to the source priv via _build symlinks.
  # Falls back to the source-relative literal if the app isn't loaded
  # (shouldn't happen in practice, since calibrator runs under the app).
  defp default_fingerprint_root do
    case :code.priv_dir(:ai_pair) do
      {:error, _} -> "priv/fingerprints"
      path -> Path.join(to_string(path), "fingerprints")
    end
  end

  # Captures only ever get committed from a developer machine, so the
  # source-tree fixture path is the right default outside a release.
  # Inside a release we route them under the inbox so the path exists
  # and is writable; the dev workflow stays unchanged.
  defp default_fixture_root do
    if System.get_env("RELEASE_NAME") do
      Path.join(default_inbox(), "fingerprints/captures")
    else
      "test/fixtures/fingerprints"
    end
  end

  defp default_inbox do
    System.get_env("AI_PAIR_INBOX") ||
      Path.join(System.user_home!(), ".ai-agent-inbox/ai-pair")
  end

  defp format_reason(%{cmd: cmd, stderr: stderr}),
    do: "tmux failed: #{Enum.join(cmd, " ")} — #{String.trim(stderr)}"

  defp format_reason({:command_not_found, bin}),
    do: "command not found on PATH: #{bin}"

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
