defmodule AiPair.Test.PaneIntentScriptedBackend do
  @moduledoc """
  A deterministic backend for `AiPair.Test.PaneIntentFaultFs`.

  It exists so the double's own controls do not depend on
  `AiPair.PaneIntentStore.Fs.SystemFs` being ABSENT. An earlier revision asserted
  `UndefinedFunctionError` from `lstat` and `mkdir`, which made backend absence a
  permanent passing condition: once GREEN supplies a real backend those operations
  return ordinary filesystem outcomes and the controls break. Scripting a backend
  lets a callback raise or return on demand whether or not SystemFs exists.

  Each operation is scripted with `{:return, value}` or `{:raise, exception}`.
  Unscripted operations answer `{:error, :not_scripted}` rather than touching the
  filesystem, so a control can never reach a real path by accident. Every call is
  recorded, which is what lets a test prove the backend was NOT entered on a
  short-circuit refusal.
  """

  @type handle :: {module(), pid()}

  @spec new() :: handle()
  def new do
    {:ok, agent} = Agent.start_link(fn -> %{script: %{}, calls: []} end)
    {__MODULE__, agent}
  end

  @spec script(handle(), atom(), {:return, term()} | {:raise, term()}) :: :ok
  def script({__MODULE__, agent}, op, action) do
    Agent.update(agent, fn s -> %{s | script: Map.put(s.script, op, action)} end)
  end

  @doc "Operations the backend actually executed, in order. Empty proves non-entry."
  @spec calls(handle()) :: [{atom(), list()}]
  def calls({__MODULE__, agent}), do: Agent.get(agent, &Enum.reverse(&1.calls))

  @spec stop(handle()) :: :ok
  def stop({__MODULE__, agent}) do
    if Process.alive?(agent), do: Agent.stop(agent), else: :ok
  end

  # Called as mod.op(state, args...) by the double's generic dispatch.
  def lstat(s, path), do: run(s, :lstat, [path])
  def mkdir(s, path), do: run(s, :mkdir, [path])
  def chmod(s, path, mode), do: run(s, :chmod, [path, mode])
  def open_exclusive(s, path), do: run(s, :open_exclusive, [path])
  def read(s, path), do: run(s, :read, [path])
  def write(s, fd, data), do: run(s, :write, [fd, data])
  def file_sync(s, fd), do: run(s, :file_sync, [fd])
  def close(s, fd), do: run(s, :close, [fd])
  def rename(s, from, to), do: run(s, :rename, [from, to])
  def directory_sync(s, dir), do: run(s, :directory_sync, [dir])
  def unlink(s, path), do: run(s, :unlink, [path])

  defp run(agent, op, args) when is_pid(agent) do
    action =
      Agent.get_and_update(agent, fn s ->
        {Map.get(s.script, op), %{s | calls: [{op, args} | s.calls]}}
      end)

    case action do
      {:return, value} -> value
      {:raise, exception} -> raise exception
      nil -> {:error, :not_scripted}
    end
  end
end

defmodule AiPair.Test.PaneIntentFaultFs do
  @moduledoc """
  A `AiPair.PaneIntentStore.Fs` that performs real filesystem work and fails on demand.

  This is a second, deliberately separate seam double from `AiPair.Test.FaultFs`.
  `AiPair.Delivery.Fs` is, by its own moduledoc, "the receipt log's own vocabulary
  rather than a general filesystem abstraction": it has no `rename`, no exclusive
  creation, no `unlink` and no `lstat`. The pane-intent store's durability sequence
  needs all four, so it carries its own seam and its own double.

  ## Events, and why they are shaped this way

  An earlier version published an outcome label *before* invoking the backend, so a
  missing backend read `:completed` and an executed hook read `:refused`. Every call
  now produces a correlated pair:

    * `{:attempt, id, op, args}` recorded before anything happens, and
    * `{:result, id, op, disposition, value}` recorded after it resolves.

  `disposition` is one of:

    * `:invoked` -- the wrapped backend call was made and returned a value.
    * `:refused` -- injection short-circuited the call; the backend was not called.
    * `:raised` -- the wrapped invocation raised or exited. Note precisely what this
      does and does not say: the call under the wrapper raised. It does NOT prove
      the backend's body was entered. An `UndefinedFunctionError` for a missing
      module, or a raising `:hook`, both surface as `:raised` with no body running.
      To prove entry, script a backend and inspect its recorded calls.
    * `:halted` -- the latch was already set; the call was attempted and refused.

  `{:fault_fired, id, op, fault}` records that a plan entry or matcher actually
  fired, so a test can assert the *targeted* fault was consumed. `count/2` counts
  attempts only: an attempt proves a callback was reached, never that a matcher
  matched.

  ## Ordering

  `events/1` is the source of truth and preserves real chronology, including where
  each result landed relative to later attempts. `effects/1` is a convenience view
  in ATTEMPT order and therefore **cannot** support an ordering claim: an
  independent witness built a stream in which `file_sync` was attempted before
  `write` returned, and the flattened view read as a valid sequence. Use
  `timeline/1`, which carries both positions, for anything reasoning about order.

  ## Backend

  The backend is a `{module, state}` handle, defaulting to
  `{AiPair.PaneIntentStore.Fs.SystemFs, nil}`, and replaceable per instance with
  `new(backend: handle)`. Controls use `AiPair.Test.PaneIntentScriptedBackend` so
  they never depend on SystemFs being absent, which would make them break the
  moment GREEN supplies it.
  """

  @behaviour AiPair.PaneIntentStore.Fs

  alias AiPair.PaneIntentStore.Fs.SystemFs

  @type handle :: {module(), pid()}
  @type disposition :: :invoked | :refused | :raised | :halted

  @spec new(keyword()) :: handle()
  def new(opts \\ []) do
    backend = Keyword.get(opts, :backend, {SystemFs, nil})

    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          plan: %{},
          matchers: [],
          counts: %{},
          events: [],
          next_id: 1,
          halted: false,
          backend: backend
        }
      end)

    {__MODULE__, agent}
  end

  @doc "Fail the `nth` call of `op`, or every call matching a one-arity predicate over its args."
  @spec inject(handle(), atom(), pos_integer() | (list() -> boolean()), term()) :: :ok
  def inject({__MODULE__, agent}, op, nth, fault) when is_integer(nth) do
    Agent.update(agent, fn state -> put_in(state.plan[{op, nth}], fault) end)
  end

  def inject({__MODULE__, agent}, op, matcher, fault) when is_function(matcher, 1) do
    Agent.update(agent, fn state ->
      %{state | matchers: state.matchers ++ [{op, matcher, fault}]}
    end)
  end

  @doc "Every recorded event in true chronological order."
  @spec events(handle()) :: [tuple()]
  def events({__MODULE__, agent}), do: Agent.get(agent, &Enum.reverse(&1.events))

  @doc """
  One record per call carrying both event positions.

  This is the view to reason about order with: `attempt_at` and `result_at` are
  indices into `events/1`, so a checker can require that a prerequisite's RESULT
  precedes a dependent's ATTEMPT.
  """
  @spec timeline(handle()) :: [map()]
  def timeline(handle) do
    indexed = Enum.with_index(events(handle))

    results =
      for {{:result, id, _op, disposition, value}, at} <- indexed,
          into: %{},
          do: {id, {disposition, value, at}}

    for {{:attempt, id, op, args}, attempt_at} <- indexed do
      {disposition, value, result_at} = Map.get(results, id, {:unresolved, nil, nil})

      %{
        id: id,
        op: op,
        args: args,
        disposition: disposition,
        value: value,
        attempt_at: attempt_at,
        result_at: result_at
      }
    end
  end

  @doc """
  Convenience view in ATTEMPT order. Never use it for an ordering claim; use
  `timeline/1`. Retained because most assertions only ask what one call did.
  """
  @spec effects(handle()) :: [{atom(), list(), disposition(), term()}]
  def effects(handle) do
    for e <- timeline(handle), do: {e.op, e.args, e.disposition, e.value}
  end

  @doc "Attempted operations in call order."
  @spec ops(handle()) :: [atom()]
  def ops(handle), do: for(e <- timeline(handle), do: e.op)

  @doc "How many times `op` was ATTEMPTED. An attempt is not proof a matcher fired."
  @spec count(handle(), atom()) :: non_neg_integer()
  def count({__MODULE__, agent}, op), do: Agent.get(agent, &Map.get(&1.counts, op, 0))

  @doc "Faults that actually fired, in order. This is the consumption witness."
  @spec faults_fired(handle()) :: [{atom(), list(), term()}]
  def faults_fired(handle) do
    evs = events(handle)
    args_by_id = for {:attempt, id, _op, args} <- evs, into: %{}, do: {id, args}
    for {:fault_fired, id, op, fault} <- evs, do: {op, Map.get(args_by_id, id), fault}
  end

  @doc "Whether a fault fired for `op` on arguments satisfying `pred`."
  @spec fault_fired?(handle(), atom(), (list() -> boolean())) :: boolean()
  def fault_fired?(handle, op, pred) when is_function(pred, 1) do
    Enum.any?(faults_fired(handle), fn {o, args, _f} ->
      o == op and is_list(args) and pred.(args)
    end)
  end

  @spec halted?(handle()) :: boolean()
  def halted?({__MODULE__, agent}), do: Agent.get(agent, & &1.halted)

  @doc "Stop the backing agent. Fixtures call this so no tracer outlives its test."
  @spec stop(handle()) :: :ok
  def stop({__MODULE__, agent}) do
    if Process.alive?(agent), do: Agent.stop(agent), else: :ok
  end

  @impl true
  def lstat(agent, path), do: perform(agent, :lstat, [path])

  @impl true
  def mkdir(agent, path), do: perform(agent, :mkdir, [path])

  @impl true
  def chmod(agent, path, mode), do: perform(agent, :chmod, [path, mode])

  @impl true
  def open_exclusive(agent, path), do: perform(agent, :open_exclusive, [path])

  @impl true
  def read(agent, path), do: perform(agent, :read, [path])

  @impl true
  def write(agent, fd, data), do: perform(agent, :write, [fd, data])

  @impl true
  def file_sync(agent, fd), do: perform(agent, :file_sync, [fd])

  @impl true
  def close(agent, fd), do: perform(agent, :close, [fd])

  @impl true
  def rename(agent, from, to), do: perform(agent, :rename, [from, to])

  @impl true
  def directory_sync(agent, dir), do: perform(agent, :directory_sync, [dir])

  @impl true
  def unlink(agent, path), do: perform(agent, :unlink, [path])

  # ------------------------------------------------------------------ internals

  defp perform(agent, op, args) do
    backend = backend_of(agent)

    case begin_call(agent, op, args) do
      {:halted, id} ->
        finish(agent, id, op, :halted, {:error, :halted})
        {:error, :halted}

      {:fault, id, fault} ->
        case run_special(agent, id, op, args, fault, backend) do
          {:handled, value} -> value
          :no_special_case -> apply_fault(agent, id, op, args, fault, backend)
        end

      {:proceed, id} ->
        invoke(agent, id, op, args, backend)
    end
  end

  # Only `write` has a special fault shape. Every exit still leaves a correlated
  # result event: an earlier version let an exception escape here between the
  # attempt and any result, recording :unresolved.
  defp run_special(agent, id, :write, [fd, data], {:torn, keep}, {bmod, bstate}) do
    # A partial write IS an effect. It is invoked, not refused.
    prefix = data |> IO.iodata_to_binary() |> binary_part(0, keep)
    _ = bmod.write(bstate, fd, prefix)
    finish(agent, id, :write, :invoked, {:error, :torn_write})
    {:handled, {:error, :torn_write}}
  catch
    kind, reason ->
      finish(agent, id, :write, :raised, {kind, reason})
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp run_special(_agent, _id, _op, _args, _fault, _backend), do: :no_special_case

  defp apply_fault(agent, id, op, args, fault, backend) do
    case fault do
      {:error, reason} ->
        finish(agent, id, op, :refused, {:error, reason})
        {:error, reason}

      {:return, value} ->
        finish(agent, id, op, :refused, value)
        value

      {:hook, fun} ->
        # A hook is a scheduling hook, not a refusal: the backend still runs.
        guarded_hook(agent, id, op, fun)
        invoke(agent, id, op, args, backend)

      :halt ->
        Agent.update(agent_pid(agent), &%{&1 | halted: true})
        finish(agent, id, op, :refused, {:error, :halted})
        {:error, :halted}

      other ->
        finish(agent, id, op, :refused, {:error, {:unsupported_fault, other}})
        {:error, {:unsupported_fault, other}}
    end
  end

  defp invoke(agent, id, op, args, {bmod, bstate}) do
    value = apply(bmod, op, [bstate | args])
    finish(agent, id, op, :invoked, value)
    value
  catch
    kind, reason ->
      finish(agent, id, op, :raised, {kind, reason})
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp guarded_hook(agent, id, op, fun) do
    _ = fun.()
    :ok
  catch
    kind, reason ->
      finish(agent, id, op, :raised, {kind, reason})
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  # The seam is invoked with the agent pid as its state, so both shapes appear.
  defp agent_pid({__MODULE__, agent}), do: agent
  defp agent_pid(agent) when is_pid(agent), do: agent

  defp backend_of(agent), do: Agent.get(agent_pid(agent), & &1.backend)

  defp begin_call(agent, op, args) do
    Agent.get_and_update(agent_pid(agent), fn state ->
      id = state.next_id
      n = Map.get(state.counts, op, 0) + 1

      state = %{
        state
        | next_id: id + 1,
          counts: Map.put(state.counts, op, n),
          events: [{:attempt, id, op, args} | state.events]
      }

      if state.halted do
        {{:halted, id}, state}
      else
        fault =
          case Map.fetch(state.plan, {op, n}) do
            {:ok, fault} ->
              fault

            :error ->
              Enum.find_value(state.matchers, fn
                {^op, matcher, fault} -> if matcher.(args), do: fault
                _ -> nil
              end)
          end

        if fault do
          {{:fault, id, fault}, %{state | events: [{:fault_fired, id, op, fault} | state.events]}}
        else
          {{:proceed, id}, state}
        end
      end
    end)
  end

  defp finish(agent, id, op, disposition, value) do
    Agent.update(agent_pid(agent), fn state ->
      %{state | events: [{:result, id, op, disposition, value} | state.events]}
    end)
  end
end
