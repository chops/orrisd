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

  ## Two censuses

  `list_panes/1` is the lossy census. It reports the fields the send path
  needs, coerces what it can and drops a row it cannot read. Callers that
  only need to address a pane keep using it unchanged.

  `observe_panes/1` is the strict census, added beside the lossy one rather
  than replacing it. It reports a session's stable id alongside its reusable
  name, and it neither drops nor coerces: a row it cannot read wholly fails
  the whole call with a typed reason. An unreadable census is never reported
  as an empty one, because a caller deciding what a pane is cannot tell an
  empty result from a census it failed to parse.

  Both censuses use the same escaped-printable framing: every free-text field
  has `%` and `|` percent-escaped by tmux before `|` joins the row, so the
  field count of a row never depends on the locale tmux runs under or on the
  bytes a field contains.

  ## Session options

  `show_options/3`, `set_option/4` and `set_option_if_absent/4` are the
  session-option calls. They exist so that a caller storing state on a tmux
  session has no reason to reach around this module and run `show-options` /
  `set-option` itself: an operation that runs from its own caller is not
  ordered by this process's mailbox, and a serialization point with an
  exception does not serialize.

  ## Scope

  This module provides boundary primitives. Per-pane queueing, debounce,
  and send eligibility belong to the per-pane `:gen_statem`.
  """

  use GenServer

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  @type pane_id :: String.t()
  @type buffer_name :: String.t()
  @type target :: String.t()
  @type option_name :: String.t()
  @type pane_info :: %{
          id: String.t(),
          session: String.t(),
          window: integer(),
          pane: integer(),
          pid: integer(),
          command: String.t()
        }
  @type error :: %{cmd: [String.t()], status: integer(), stderr: binary()}

  @typedoc """
  One strictly parsed pane row. The key set is exact: consumers compare these
  observations against independently recorded intent, and treat an unexpected,
  missing or wrongly typed key as a defect in this producer.
  """
  @type observation :: %{
          pane_id: String.t(),
          session_id: String.t(),
          session_name: String.t(),
          window_index: non_neg_integer(),
          pane_index: non_neg_integer(),
          pane_pid: pos_integer(),
          command: String.t(),
          path: String.t()
        }

  @typedoc """
  Why a census could not be read. Each reason names the offending field
  verbatim rather than summarising it; `:row_arity` carries the expected
  field count, the observed count, and the zero-based index of the row.
  """
  @type census_error ::
          {:row_arity, pos_integer(), non_neg_integer(), non_neg_integer()}
          | {:malformed_pid, String.t()}
          | {:malformed_index, :window_index | :pane_index, String.t()}
          | {:malformed_text, :pane_id | :session_id | :session_name | :command | :path, binary()}

  # tmux sanitizes literal tab separators in C locales; escape printable fields instead.
  @list_panes_format "\#{pane_id}|\#{s/%/%25/;s/[|]/%7C/:session_name}|\#{window_index}|\#{pane_index}|\#{pane_pid}|\#{s/%/%25/;s/[|]/%7C/:pane_current_command}"

  # The strict census uses the same escaped-printable framing as @list_panes_format.
  # A tab-separated format was measured to lose 24 rows to row-arity failures under
  # the C locale; percent-escaping the free-text fields keeps the arity independent
  # of the locale and of the field values. pane_id and session_id are tmux-minted
  # (`%N`, `$N`) and can never contain the separator, so they are framed raw.
  @observe_panes_format "\#{pane_id}|\#{session_id}|\#{s/%/%25/;s/[|]/%7C/:session_name}|\#{window_index}|\#{pane_index}|\#{pane_pid}|\#{s/%/%25/;s/[|]/%7C/:pane_current_command}|\#{s/%/%25/;s/[|]/%7C/:pane_current_path}"

  # Stated, not derived from @observe_panes_format. Deriving it would make the
  # format and the parser agree by construction, and an agreement that cannot
  # fail proves nothing: a field added to the format without a matching parser
  # clause must be caught as a disagreement, not discovered as a census in which
  # every row has become unparseable.
  @observation_arity 8

  @decimal_format ~r/\A[0-9]+\z/
  @option_exists_marker "already set: "
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

  @doc """
  The tmux `-F` format string of the strict census.

  Its fields, in order, joined by `|`: pane id, session id, session name,
  window index, pane index, pane pid, current command, current path. The
  three free-text fields (session name, command, path) are emitted through
  tmux's `s/%/%25/;s/[|]/%7C/` substitution and decoded by the parser in the
  reverse order (the `|` escape first, then the `%` escape), exactly as
  `list_panes/1` does.
  """
  @spec observe_format() :: String.t()
  def observe_format, do: @observe_panes_format

  @doc """
  How many fields `observe_format/0` emits and `parse_observations/1` requires.

  Stated independently of the format string so that the two are able to
  disagree, and so that a disagreement is what fails.
  """
  @spec observation_arity() :: pos_integer()
  def observation_arity, do: @observation_arity

  @doc """
  Takes a strict census of every pane on the server
  (`list-panes -a -F <observe_format/0>`).

  Reports each session's stable id (`$N`) as well as its reusable name, and
  refuses to answer partially: if any row cannot be read wholly the entire
  call is `{:error, census_error()}`, never a shorter list of the rows that
  happened to parse. Empty output is `{:ok, []}`, a claim that the server has
  no panes, which is a different claim from having failed to read it.

  A failing tmux invocation returns the usual `{:error, error()}` map.
  """
  @spec observe_panes(GenServer.server()) ::
          {:ok, [observation()]} | {:error, census_error()} | {:error, error()}
  def observe_panes(server \\ __MODULE__) do
    Tracer.with_span "tmux.observe_panes", %{kind: :internal, attributes: %{}} do
      result = GenServer.call(server, :observe_panes, @default_call_timeout_ms)
      annotate_observe(result)
      result
    end
  end

  @doc """
  Parses raw `observe_format/0` output into observations.

  No field is coerced. A pid field of `"12abc"` is
  `{:error, {:malformed_pid, "12abc"}}` rather than the integer `12` that
  `Integer.parse/1` yields from it, because a field that is only partly a
  number identifies no process. A pane id that does not start with `%`, a
  session id that does not start with `$`, and an empty or non-UTF-8 text
  field are each `{:error, {:malformed_text, key, field}}`.
  """
  @spec parse_observations(binary()) :: {:ok, [observation()]} | {:error, census_error()}
  def parse_observations(output) when is_binary(output) do
    output
    |> census_rows()
    |> parse_rows(0, [])
  end

  @doc """
  Reads one option's value from `target` (`show-options -t <target> -v <option>`).

  The raw tmux output is reported verbatim, trailing newline included: a caller
  that stores a structured value decodes it itself rather than having this
  boundary guess at a shape it does not own.

  The failure is reported unclassified. tmux exits 1 both for an option that is
  unset and for a target it cannot address, and separates the two only in its
  message, so which one happened is decided by the caller against its own
  vocabulary; `-q` would erase the evidence that decision needs.
  """
  @spec show_options(target(), option_name(), GenServer.server()) ::
          {:ok, binary()} | {:error, error()}
  def show_options(target, option, server \\ __MODULE__) do
    tmux_span("show_options", %{"tmux.target" => target, "tmux.option" => option}, fn ->
      GenServer.call(server, {:show_options, target, option}, @default_call_timeout_ms)
    end)
  end

  @doc """
  Sets one option on `target` (`set-option -t <target> <option> <value>`).

  Unconditional: writing a value identical to the stored one is still a write,
  and nothing here suppresses it. A caller that must not rewrite an unchanged
  value reads first and decides for itself.

  The value is never recorded as a span attribute, only its size, since an
  option value is caller data of unknown sensitivity.
  """
  @spec set_option(target(), option_name(), String.t(), GenServer.server()) ::
          :ok | {:error, error()}
  def set_option(target, option, value, server \\ __MODULE__) when is_binary(value) do
    tmux_span(
      "set_option",
      %{
        "tmux.target" => target,
        "tmux.option" => option,
        "tmux.value_bytes" => byte_size(value)
      },
      fn ->
        GenServer.call(server, {:set_option, target, option, value}, @default_call_timeout_ms)
      end
    )
  end

  @doc """
  Sets an option only when it is absent
  (`set-option -o -t <target> <option> <value>`).

  tmux refuses the write when the option already exists, exits non-zero and
  reports `already set: <option>`; that refusal is returned as the typed
  `{:error, :option_exists}` and is never reported as success. An existing
  option is left unchanged; callers read the value back to learn which claim
  won. Every other failure keeps the `{:error, error()}` map.
  """
  @spec set_option_if_absent(target(), option_name(), String.t(), GenServer.server()) ::
          :ok | {:error, :option_exists} | {:error, error()}
  def set_option_if_absent(target, option, value, server \\ __MODULE__) when is_binary(value) do
    tmux_span(
      "set_option_if_absent",
      %{
        "tmux.target" => target,
        "tmux.option" => option,
        "tmux.value_bytes" => byte_size(value)
      },
      fn ->
        GenServer.call(
          server,
          {:set_option_if_absent, target, option, value},
          @default_call_timeout_ms
        )
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

  def handle_call(:observe_panes, _from, state) do
    {:reply, do_observe_panes(state), state}
  end

  def handle_call({:show_options, target, option}, _from, state) do
    {:reply, do_show_options(state, target, option), state}
  end

  def handle_call({:set_option, target, option, value}, _from, state) do
    {:reply, do_set_option(state, target, option, value), state}
  end

  def handle_call({:set_option_if_absent, target, option, value}, _from, state) do
    {:reply, do_set_option_if_absent(state, target, option, value), state}
  end

  # ===== Implementation =====

  defp do_list_panes(state) do
    args = ["list-panes", "-a", "-F", @list_panes_format]

    case run_tmux(state, args) do
      {:ok, output} -> {:ok, parse_pane_list(output)}
      {:error, _} = err -> err
    end
  end

  defp do_observe_panes(state) do
    args = ["list-panes", "-a", "-F", @observe_panes_format]

    case run_tmux(state, args) do
      {:ok, output} -> parse_observations(output)
      {:error, _} = err -> err
    end
  end

  defp do_show_options(state, target, option) do
    run_tmux(state, ["show-options", "-t", target, "-v", option])
  end

  defp do_set_option(state, target, option, value) do
    discard_ok(run_tmux(state, ["set-option", "-t", target, option, value]))
  end

  defp do_set_option_if_absent(state, target, option, value) do
    case run_tmux(state, ["set-option", "-o", "-t", target, option, value]) do
      {:ok, _} -> :ok
      {:error, err} -> classify_conditional_set(err)
    end
  end

  # tmux answers a `-o` write over an existing option with `already set: <option>`
  # on stderr and a non-zero exit. That exact refusal is the typed result; any
  # other failure (unknown target, missing binary) keeps the raw map so the
  # caller can tell a lost race from an unreachable session.
  defp classify_conditional_set(%{status: status, stderr: stderr} = err) do
    if status > 0 and String.contains?(stderr, @option_exists_marker) do
      {:error, :option_exists}
    else
      {:error, err}
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

  # ===== Strict census =====

  # A trailing newline terminates the final row rather than starting an empty
  # one, so exactly one is removed. Everything else that occupies a line is
  # treated as a row: a blank line is reported as a row of the wrong width
  # rather than skipped, because skipping it would shorten the census silently.
  defp census_rows(""), do: []

  defp census_rows(output) do
    output
    |> strip_row_terminator()
    |> String.split("\n")
  end

  defp strip_row_terminator(output) do
    if String.ends_with?(output, "\n") do
      binary_part(output, 0, byte_size(output) - 1)
    else
      output
    end
  end

  defp parse_rows([], _index, acc), do: {:ok, Enum.reverse(acc)}

  defp parse_rows([row | rest], index, acc) do
    case parse_row(String.split(row, "|"), index) do
      {:ok, observation} -> parse_rows(rest, index + 1, [observation | acc])
      {:error, _failure} = error -> error
    end
  end

  # Field order here is the field order of @observe_panes_format, and the two
  # are kept in step by @observation_arity rather than by inspection. The three
  # free-text fields are percent-decoded with the same codec as list_panes/1;
  # pane_id and session_id are framed raw by the format and read raw here.
  defp parse_row(
         [pane_id, session_id, session_name, window_index, pane_index, pane_pid, command, path],
         _index
       ) do
    with {:ok, id} <- prefixed_field(:pane_id, "%", pane_id),
         {:ok, session} <- prefixed_field(:session_id, "$", session_id),
         {:ok, name} <- text_field(:session_name, decode_pane_field(session_name)),
         {:ok, window} <- index_field(:window_index, window_index),
         {:ok, pane} <- index_field(:pane_index, pane_index),
         {:ok, pid} <- pid_field(pane_pid),
         {:ok, cmd} <- text_field(:command, decode_pane_field(command)),
         {:ok, cwd} <- text_field(:path, decode_pane_field(path)) do
      {:ok,
       %{
         pane_id: id,
         session_id: session,
         session_name: name,
         window_index: window,
         pane_index: pane,
         pane_pid: pid,
         command: cmd,
         path: cwd
       }}
    end
  end

  defp parse_row(fields, index) do
    {:error, {:row_arity, @observation_arity, length(fields), index}}
  end

  # Presence is checked, because an empty field is a field tmux did not answer,
  # and so is UTF-8 validity, because every consumer records these as text.
  # Nothing more about the shape of a name, command or path is assumed.
  defp text_field(key, field) do
    if field != "" and String.valid?(field) do
      {:ok, field}
    else
      {:error, {:malformed_text, key, field}}
    end
  end

  # tmux mints pane ids as `%N` and session ids as `$N`. Only the sigil is
  # checked: a caller comparing ids against recorded intent owns the rest.
  defp prefixed_field(key, sigil, field) do
    with {:ok, value} <- text_field(key, field) do
      if String.starts_with?(value, sigil) and byte_size(value) > byte_size(sigil) do
        {:ok, value}
      else
        {:error, {:malformed_text, key, value}}
      end
    end
  end

  defp index_field(key, field) do
    case decimal(field) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:malformed_index, key, field}}
    end
  end

  # `Integer.parse/1` reads "12abc" as 12, and that 12 is then indistinguishable
  # from a pid read correctly. The whole field must be the number, and 0 is no
  # process.
  defp pid_field(field) do
    case decimal(field) do
      {:ok, value} when value > 0 -> {:ok, value}
      {:ok, 0} -> {:error, {:malformed_pid, field}}
      :error -> {:error, {:malformed_pid, field}}
    end
  end

  defp decimal(field) do
    if Regex.match?(@decimal_format, field) do
      {:ok, String.to_integer(field)}
    else
      :error
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

  # A refused conditional write is a typed outcome rather than an invocation
  # failure: tmux exited 1 by design, so the class names the refusal.
  defp annotate_tmux_result({:error, :option_exists}) do
    Tracer.set_attribute("tmux.exit_status", 1)
    Tracer.set_attribute("tmux.error_class", "option_exists")
    Tracer.set_status(:error, "tmux exit=1: option already set")
  end

  defp annotate_observe({:ok, observations}) do
    Tracer.set_attribute("tmux.exit_status", 0)
    Tracer.set_attribute("census.pane_count", length(observations))
  end

  defp annotate_observe({:error, err}) when is_map(err) do
    Tracer.set_attribute("tmux.exit_status", err.status)
    Tracer.set_attribute("tmux.error_class", classify_error(err))
    Tracer.set_status(:error, short_error(err))
  end

  # An unreadable census is not a failed invocation: tmux exited 0 and we could
  # not read what it printed, so the kind of the typed reason is recorded
  # instead of an exit status. An unrecognised reason raises here rather than
  # being flattened into a generic error, which is how a new reason gets annotated.
  defp annotate_observe({:error, failure}), do: annotate_census_failure(failure)

  defp annotate_census_failure({:row_arity, expected, got, row}) do
    census_error("row_arity", "row #{row} has #{got} fields, expected #{expected}")
  end

  defp annotate_census_failure({:malformed_pid, field}) do
    census_error("malformed_pid", "pane_pid is not a positive decimal: #{inspect(field)}")
  end

  defp annotate_census_failure({:malformed_index, key, field}) do
    census_error("malformed_index", "#{key} is not a decimal index: #{inspect(field)}")
  end

  defp annotate_census_failure({:malformed_text, key, field}) do
    census_error("malformed_text", "#{key} is empty or not valid text: #{inspect(field)}")
  end

  defp census_error(kind, detail) do
    Tracer.set_attribute("census.error_kind", kind)
    Tracer.set_status(:error, "tmux census unreadable: #{detail}")
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
