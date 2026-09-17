defmodule AiPair.Tmux do
  @moduledoc """
  Boundary module for every tmux invocation in the system.

  All `System.cmd("tmux", ...)` calls funnel through this single GenServer
  so that we never have two tmux operations racing. This is a deliberate
  serialization point — fan-out happens above (per-pane state machines)
  and below (kernel-level tmux), but the boundary itself is single-file.

  ## Test isolation

  Pass `:socket_name` at start_link to scope every invocation to a dedicated
  tmux server (`tmux -L <name>`). Production uses the user's default tmux
  socket; tests use a unique name so they cannot touch the user's session.

  ## Failure shape

  All API functions return `{:ok, result}` or `{:error, error()}`, where
  `error()` is `%{cmd: [String.t()], status: integer(), stderr: binary()}`.
  Raw `System.cmd/3` tuples never escape this module.

  ## Scope

  This module provides boundary primitives. Per-pane queueing, debounce,
  and send eligibility belong to the per-pane `:gen_statem`.
  """

  use GenServer

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  @type pane_id :: String.t()
  @type buffer_name :: String.t()
  @type pane_info :: %{
          id: String.t(),
          session: String.t(),
          window: integer(),
          pane: integer(),
          pid: integer(),
          command: String.t()
        }
  @type error :: %{cmd: [String.t()], status: integer(), stderr: binary()}

  # tmux sanitizes literal tab separators in C locales; escape printable fields instead.
  @list_panes_format "\#{pane_id}|\#{s/%/%25/;s/[|]/%7C/:session_name}|\#{window_index}|\#{pane_index}|\#{pane_pid}|\#{s/%/%25/;s/[|]/%7C/:pane_current_command}"
  @default_call_timeout_ms 5_000
  @capture_call_timeout_ms 1_000

  # ===== Public API =====

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec list_panes(GenServer.server()) :: {:ok, [pane_info()]} | {:error, error()}
  def list_panes(server \\ __MODULE__) do
    tmux_span("list_panes", %{}, fn ->
      GenServer.call(server, :list_panes, @default_call_timeout_ms)
    end)
  end

  @doc """
  Captures the current visible content of a pane. Default flags:
    `-p` print to stdout, `-e` preserve escapes, `-J` join wrapped lines.

  Options:
    * `:history` — `true` to include scrollback (uses `-S -`)
    * `:start`, `:end` — explicit `-S` / `-E` line numbers

  ## Error shape

  Unlike the other API functions, the capture path normalizes one error
  class to a typed atom: when tmux's stderr indicates the pane no longer
  exists (`"can't find pane"` / `"no such pane"`), the call returns
  `{:error, :pane_gone}`. All other failures return `{:error, error()}`
  with the raw map for diagnostics. The state machine relies on this
  distinction to drive its dead-pane reaper without treating transient
  tmux failures as reasons to mark a pane dead.
  """
  @spec capture_pane(pane_id(), keyword(), GenServer.server()) ::
          {:ok, binary()} | {:error, :pane_gone} | {:error, error()}
  def capture_pane(pane_id, opts \\ [], server \\ __MODULE__) do
    Tracer.with_span "tmux.capture", %{
      kind: :internal,
      attributes:
        drop_nils(%{
          "pane.id" => pane_id,
          "tmux.history" => if(Keyword.get(opts, :history) == true, do: true)
        })
    } do
      result = capture_call(server, pane_id, opts)
      annotate_capture(result)
      normalize_capture_error(result)
    end
  end

  # Bound read-only polling below the outer pane status call deadline.
  # Never apply this containment or an automatic retry to mutating calls.
  defp capture_call(server, pane_id, opts) do
    GenServer.call(server, {:capture_pane, pane_id, opts}, @capture_call_timeout_ms)
  catch
    :exit, {:timeout, {GenServer, :call, _}} ->
      capture_unavailable(pane_id, 124, "tmux capture request timed out")

    :exit, {:noproc, {GenServer, :call, _}} ->
      capture_unavailable(pane_id, 125, "tmux capture backend unavailable")
  end

  defp capture_unavailable(pane_id, status, reason) do
    {:error, %{cmd: ["capture-pane", "-t", pane_id], status: status, stderr: reason}}
  end

  @doc """
  Sends a list of key names to a pane (e.g. `["Enter"]`, `["C-c"]`).

  This is for control keys only. Content injection MUST go through
  `set_buffer/2` + `paste_buffer/3` for bracketed-paste correctness.
  """
  @spec send_keys(pane_id(), [String.t()], GenServer.server()) :: :ok | {:error, error()}
  def send_keys(pane_id, keys, server \\ __MODULE__) when is_list(keys) do
    tmux_span(
      "send_keys",
      %{"pane.id" => pane_id, "tmux.key_count" => length(keys)},
      fn -> GenServer.call(server, {:send_keys, pane_id, keys}, @default_call_timeout_ms) end
    )
  end

  @spec set_buffer(buffer_name(), binary(), GenServer.server()) :: :ok | {:error, error()}
  def set_buffer(name, payload, server \\ __MODULE__) when is_binary(payload) do
    tmux_span(
      "set_buffer",
      %{"tmux.buffer_name" => name, "tmux.payload_bytes" => byte_size(payload)},
      fn -> GenServer.call(server, {:set_buffer, name, payload}, @default_call_timeout_ms) end
    )
  end

  @doc """
  Pastes a buffer into a pane. Defaults: `-p` (bracketed paste), `-r`
  (preserve LF, do not translate to CR). Caller may pass `delete: true`
  to add `-d` and remove the buffer after paste.
  """
  @spec paste_buffer(pane_id(), buffer_name(), keyword(), GenServer.server()) ::
          :ok | {:error, error()}
  def paste_buffer(pane_id, name, opts \\ [], server \\ __MODULE__) do
    Tracer.with_span "tmux.paste", %{
      kind: :internal,
      attributes:
        drop_nils(%{
          "pane.id" => pane_id,
          "tmux.buffer_name" => name,
          "tmux.delete_after" => if(Keyword.get(opts, :delete) == true, do: true)
        })
    } do
      result =
        GenServer.call(server, {:paste_buffer, pane_id, name, opts}, @default_call_timeout_ms)

      annotate_paste(result)
      result
    end
  end

  @spec delete_buffer(buffer_name(), GenServer.server()) :: :ok | {:error, error()}
  def delete_buffer(name, server \\ __MODULE__) do
    tmux_span("delete_buffer", %{"tmux.buffer_name" => name}, fn ->
      GenServer.call(server, {:delete_buffer, name}, @default_call_timeout_ms)
    end)
  end

  @spec display_message(pane_id(), String.t(), GenServer.server()) :: :ok | {:error, error()}
  def display_message(pane_id, message, server \\ __MODULE__) do
    tmux_span(
      "display_message",
      %{"pane.id" => pane_id, "tmux.message_bytes" => byte_size(message)},
      fn ->
        GenServer.call(server, {:display_message, pane_id, message}, @default_call_timeout_ms)
      end
    )
  end

  # ===== GenServer =====

  @impl true
  def init(opts) do
    state = %{
      tmux_bin: Keyword.get(opts, :tmux_bin, "tmux"),
      socket_name: Keyword.get(opts, :socket_name)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:list_panes, _from, state) do
    {:reply, do_list_panes(state), state}
  end

  def handle_call({:capture_pane, pane_id, opts}, _from, state) do
    {:reply, do_capture_pane(state, pane_id, opts), state}
  end

  def handle_call({:send_keys, pane_id, keys}, _from, state) do
    {:reply, do_send_keys(state, pane_id, keys), state}
  end

  def handle_call({:set_buffer, name, payload}, _from, state) do
    {:reply, do_set_buffer(state, name, payload), state}
  end

  def handle_call({:paste_buffer, pane_id, name, opts}, _from, state) do
    {:reply, do_paste_buffer(state, pane_id, name, opts), state}
  end

  def handle_call({:delete_buffer, name}, _from, state) do
    {:reply, do_delete_buffer(state, name), state}
  end

  def handle_call({:display_message, pane_id, message}, _from, state) do
    {:reply, do_display_message(state, pane_id, message), state}
  end

  # ===== Implementation =====

  defp do_list_panes(state) do
    args = ["list-panes", "-a", "-F", @list_panes_format]

    case run_tmux(state, args) do
      {:ok, output} -> {:ok, parse_pane_list(output)}
      {:error, _} = err -> err
    end
  end

  defp do_capture_pane(state, pane_id, opts) do
    base = ["capture-pane", "-p", "-e", "-J", "-t", pane_id]

    range_args =
      cond do
        Keyword.get(opts, :history) == true -> ["-S", "-"]
        Keyword.has_key?(opts, :start) -> ["-S", to_string(Keyword.fetch!(opts, :start))]
        true -> []
      end

    end_args =
      case Keyword.fetch(opts, :end) do
        {:ok, e} -> ["-E", to_string(e)]
        :error -> []
      end

    run_tmux(state, base ++ range_args ++ end_args)
  end

  defp do_send_keys(state, pane_id, keys) do
    discard_ok(run_tmux(state, ["send-keys", "-t", pane_id | keys]))
  end

  defp do_set_buffer(state, name, payload) do
    discard_ok(run_tmux(state, ["set-buffer", "-b", name, "--", payload]))
  end

  defp do_paste_buffer(state, pane_id, name, opts) do
    delete_flag = if Keyword.get(opts, :delete) == true, do: ["-d"], else: []
    args = ["paste-buffer", "-p", "-r"] ++ delete_flag ++ ["-b", name, "-t", pane_id]
    discard_ok(run_tmux(state, args))
  end

  defp do_delete_buffer(state, name) do
    discard_ok(run_tmux(state, ["delete-buffer", "-b", name]))
  end

  defp do_display_message(state, pane_id, message) do
    discard_ok(run_tmux(state, ["display-message", "-t", pane_id, "--", message]))
  end

  defp discard_ok({:ok, _}), do: :ok
  defp discard_ok({:error, _} = err), do: err

  # ===== Helpers =====

  defp run_tmux(state, args) do
    full_args = prepend_socket(state, args)

    try do
      case System.cmd(state.tmux_bin, full_args, stderr_to_stdout: true) do
        {output, 0} ->
          {:ok, output}

        {output, status} ->
          {:error, %{cmd: [state.tmux_bin | full_args], status: status, stderr: output}}
      end
    rescue
      e in [ErlangError, File.Error] ->
        if enoent?(e) do
          Logger.error(fn ->
            "ai_pair: tmux binary not found on PATH while running " <>
              inspect([state.tmux_bin | full_args])
          end)
        end

        {:error, %{cmd: [state.tmux_bin | full_args], status: -1, stderr: Exception.message(e)}}
    end
  end

  defp enoent?(%ErlangError{original: :enoent}), do: true
  defp enoent?(%File.Error{reason: :enoent}), do: true
  defp enoent?(_), do: false

  defp prepend_socket(%{socket_name: nil}, args), do: args
  defp prepend_socket(%{socket_name: name}, args), do: ["-L", name | args]

  defp parse_pane_list(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_pane_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_pane_line(line) do
    case String.split(line, "|") do
      [id, session, window, pane, pid, command] ->
        %{
          id: id,
          session: decode_pane_field(session),
          window: parse_int(window),
          pane: parse_int(pane),
          pid: parse_int(pid),
          command: decode_pane_field(command)
        }

      _ ->
        nil
    end
  end

  defp decode_pane_field(value) do
    value |> String.replace("%7C", "|") |> String.replace("%25", "%")
  end

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  # Generic wrapper for tmux ops without bespoke attribute helpers.
  # `capture`/`paste` keep their own `annotate_*` because they record
  # extra payload-shape attrs (bytes, line_count) that aren't useful
  # for the simpler ops.
  defp tmux_span(name, attrs, fun) do
    Tracer.with_span "tmux.#{name}", %{
      kind: :internal,
      attributes: drop_nils(attrs)
    } do
      result = fun.()
      annotate_tmux_result(result)
      result
    end
  end

  defp annotate_tmux_result(:ok), do: Tracer.set_attribute("tmux.exit_status", 0)
  defp annotate_tmux_result({:ok, _}), do: Tracer.set_attribute("tmux.exit_status", 0)

  defp annotate_tmux_result({:error, err}) when is_map(err) do
    Tracer.set_attribute("tmux.exit_status", err.status)
    Tracer.set_attribute("tmux.error_class", classify_error(err))
    Tracer.set_status(:error, short_error(err))
  end

  defp annotate_capture({:ok, output}) do
    Tracer.set_attribute("tmux.exit_status", 0)
    Tracer.set_attribute("capture.bytes", byte_size(output))
    Tracer.set_attribute("capture.line_count", count_lines(output))
  end

  defp annotate_capture({:error, err}) do
    Tracer.set_attribute("tmux.exit_status", err.status)
    Tracer.set_attribute("tmux.error_class", classify_error(err))
    Tracer.set_status(:error, short_error(err))
  end

  defp annotate_paste(:ok) do
    Tracer.set_attribute("tmux.exit_status", 0)
  end

  defp annotate_paste({:error, err}) do
    Tracer.set_attribute("tmux.exit_status", err.status)
    Tracer.set_attribute("tmux.error_class", classify_error(err))
    Tracer.set_status(:error, short_error(err))
  end

  defp classify_error(%{status: -1}), do: "binary_not_found"

  defp classify_error(%{stderr: stderr}) do
    cond do
      stderr =~ "can't find pane" -> "pane_not_found"
      stderr =~ "no such pane" -> "pane_not_found"
      true -> "nonzero_exit"
    end
  end

  defp normalize_capture_error({:ok, _} = ok), do: ok

  defp normalize_capture_error({:error, err}) do
    case classify_error(err) do
      "pane_not_found" -> {:error, :pane_gone}
      _ -> {:error, err}
    end
  end

  defp short_error(%{stderr: stderr, status: status}) do
    first_line =
      stderr
      |> String.split("\n", parts: 2)
      |> List.first()
      |> String.slice(0, 120)

    "tmux exit=#{status}: #{first_line}"
  end

  defp count_lines(content) when is_binary(content) do
    content |> :binary.matches("\n") |> length()
  end

  defp drop_nils(map) do
    map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()
  end
end
