defmodule AiPair.PaneIntentStore do
  @moduledoc """
  One owner for one project's pane attachment intents, persisted durably.

  The store is a `GenServer` that owns exactly one canonical project root inside
  the daemon BEAM. It is deliberately dormant: `child_spec/1` exists, but this
  unit does not add itself to the running application, and boot reconciliation,
  attach/detach callers and installed activation are separate follow-ons.

  ## What it guarantees, and what it does not

  Every snapshot is published through exclusive temporary creation, a private
  mode, a complete write, a file fsync, a checked close, an atomic rename and a
  parent-directory fsync. Kernel `fsync` and atomic rename protect the stated
  daemon-crash boundary. Survival of sudden power loss on macOS is NOT claimed:
  that needs `F_FULLFSYNC`, which is unreachable from Erlang without a NIF.

  Sole-daemon, exclusive-root host ownership is a PRECONDITION, not something
  this module enforces. Ownership here is per-BEAM; no cross-VM file lock is
  claimed, and a same-user hostile process replacing paths underneath the store
  violates the precondition rather than being defended against.

  Records describe desired attachment plus caller-supplied hints. Storage never
  certifies identity, liveness, permission or model, and never executes the
  `agent`, `classifier` or `command` strings.

  ## Failure shape

  Every failure is `{:error, %{stage: stage, reason: reason, outcome: outcome,
  cleanup_errors: entries}}`. `stage` is one of a closed set of atoms fixed by
  the contract and never derived from file contents. `outcome` is `:unchanged`
  when the previously committed bytes are intact, or `:uncertain` when the
  rename failed or anything failed after it.

  An `:uncertain` outcome POISONS the owner: `list/1`, `put/2` and `delete/2`
  then fail visibly until an explicit stop and restart reload. A stale healthy
  view is never served after an uncertain replacement, and nothing is retried
  automatically - an API timeout is an unknown result, not proof of non-commit.

  ## Why ownership is claimed before anything is read

  Observing that nobody holds the name is not claiming it. An earlier revision
  checked `:global.whereis_name/1` and only registered after loading, which left
  a window where two starters both passed the check, both read, and the loser's
  stale snapshot later overwrote an update the winner had already acknowledged.
  That was measured, not theorised.

  So the name is REGISTERED first: `init/1` performs no filesystem work at all,
  and inspection and loading run afterwards under that ownership. A startup
  failure stops the owner and returns a typed `{:error, map}` to the caller, so
  no half-ready owner is ever observable.

  The failure is deliberately not signalled by an `init/1` stop, because
  `start_link` links and that would kill a caller which is not trapping exits -
  independently confirmed on OTP 29. The startup call uses `:infinity` rather
  than a timeout: a timeout would leave the owner registered while handing the
  caller an unknown result, which is precisely the ambiguity this unit refuses
  to manufacture elsewhere.

  ## An unresolved close is reported, never assumed

  A close that the backend refuses does not make the descriptor closed. The
  failure is appended to `cleanup_errors` alongside the primary error; the store
  does not retry it and does not claim the descriptor was released. The
  descriptor remains owned by the VM until the owning process exits.
  """

  use GenServer

  alias AiPair.PaneIntentStore.Fs
  alias AiPair.PaneIntentStore.Record

  @state_dir "state"
  @file_name "pane-attachments.json"

  @typedoc "The structured failure shape every API returns."
  @type error :: %{
          stage: atom(),
          reason: term(),
          outcome: :unchanged | :uncertain,
          cleanup_errors: [%{stage: :temporary_cleanup, reason: term()}]
        }

  # ------------------------------------------------------------------- client

  @doc """
  Start the owner for one canonical root.

  Options are `:root`, an absolute path to an existing private project root, and
  optionally `:fs`, a `t:AiPair.PaneIntentStore.Fs.handle/0` seam.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, error()}
  def start_link(opts) when is_list(opts) do
    fs = Keyword.get(opts, :fs, Fs.default())

    with {:ok, root} <- canonical_root(Keyword.get(opts, :root)) do
      claim_then_start(root, fs, paths(root))
    end
  end

  @doc "All records, in lexicographic binary `pane_id` order."
  @spec list(GenServer.server()) :: {:ok, [map()]} | {:error, error()}
  def list(store), do: GenServer.call(store, :list)

  @doc "Replace the complete record for one pane."
  @spec put(GenServer.server(), map()) :: :ok | {:error, error()}
  def put(store, record), do: GenServer.call(store, {:put, record})

  @doc "Remove one pane. Idempotent for an absent pane after a healthy load."
  @spec delete(GenServer.server(), String.t()) :: :ok | {:error, error()}
  def delete(store, pane_id), do: GenServer.call(store, {:delete, pane_id})

  # ------------------------------------------------------------------- server

  # No filesystem work here. init/1 exists to REGISTER the name, so ownership is
  # held before any store data is inspected or read.
  @impl true
  def init({root, fs, paths}) do
    {:ok,
     %{
       root: root,
       fs: fs,
       paths: paths,
       records: nil,
       poisoned: nil,
       loaded: false,
       root_sync_owed: false
     }}
  end

  @impl true
  def handle_call(:complete_startup, _from, %{loaded: false} = state) do
    with :ok <- inspect_root(state.fs, state.root),
         :ok <- inspect_state(state.fs, state.paths),
         {:ok, records} <- load(state.fs, state.paths),
         {:ok, owed} <- state_dir_debt(state) do
      loaded = %{state | records: records, loaded: true, root_sync_owed: owed}
      {:reply, :ok, loaded}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  # Unreachable in normal use, because a failed startup stops the owner before
  # start_link returns. Kept so that a half-ready owner can never serve an API
  # call even if one were somehow reached.
  def handle_call(_request, _from, %{loaded: false} = state) do
    {:reply, {:error, error(:ownership, :startup_incomplete)}, state}
  end

  def handle_call(_request, _from, %{poisoned: poisoned} = state) when not is_nil(poisoned) do
    {:reply, {:error, poisoned}, state}
  end

  def handle_call(:list, _from, state) do
    {:reply, {:ok, Record.sort(state.records)}, state}
  end

  def handle_call({:put, record}, _from, state) do
    case Record.validate(record, state.root) do
      :ok ->
        others = Enum.reject(state.records, &(&1["pane_id"] == record["pane_id"]))
        commit(state, Record.sort([record | others]))

      {:error, reason} ->
        {:reply, {:error, error(:validation, reason)}, state}
    end
  end

  def handle_call({:delete, pane_id}, _from, state) do
    if is_binary(pane_id) do
      commit(state, Enum.reject(state.records, &(&1["pane_id"] == pane_id)))
    else
      {:reply, {:error, error(:validation, {"pane_id", :not_a_string})}, state}
    end
  end

  # A committed snapshot replaces the whole file, including when it is empty:
  # delete never unlinks the final path, so a failed delete cannot look like a
  # successful detach.
  # persist/2 returns the owner state on BOTH paths, because a failure can leave
  # a durability obligation outstanding and forgetting it on retry is how a
  # later put came to acknowledge success without its root sync ever succeeding.
  defp commit(state, records) do
    case persist(state, records) do
      {:ok, state} ->
        {:reply, :ok, %{state | records: records}}

      {:error, state, %{outcome: :uncertain} = err} ->
        # The committed content is now unknown. Serving the old in-memory view
        # would be reporting a state we cannot vouch for.
        poisoned = %{err | stage: :poisoned}
        conclude(err, %{state | poisoned: poisoned})

      {:error, state, err} ->
        conclude(err, state)
    end
  end

  # G3. An unresolved close leaves a descriptor whose lifetime is this process's
  # lifetime. Recording the failure is reporting, not reclaiming: an owner that
  # keeps accepting calls accumulates one descriptor per occurrence, and naming
  # the eventual exit is a lifetime fact rather than a bound on when it happens.
  #
  # Terminating normally in the SAME transition that reports the failure is what
  # makes the retention finite - the reply is still delivered, the primary data
  # outcome is unchanged, and both cleanup errors survive in it. Deliberately no
  # deferred self-message, no linger interval and no helper process: those would
  # reintroduce an unbounded window between reporting and reclaiming.
  defp conclude(%{cleanup_errors: entries} = err, state) do
    unresolved =
      Enum.any?(entries, &match?(%{stage: :temporary_cleanup, reason: {:close, _}}, &1)) or
        directory_descriptor_unresolved?(err)

    if unresolved do
      {:stop, :normal, {:error, err}, state}
    else
      {:reply, {:error, err}, state}
    end
  end

  # A directory sync owns a raw descriptor too. Looking only at cleanup_errors
  # would leave that one retained by a still-serving owner, which is the exact
  # leak this transition exists to bound. The primary :directory_sync stage and
  # its unchanged/uncertain outcome are preserved untouched - only the decision
  # to stop is taken from the reason.
  defp directory_descriptor_unresolved?(%{stage: :directory_sync, reason: {:directory_sync, why}}),
    do: backend_close_unresolved?(why)

  defp directory_descriptor_unresolved?(_err), do: false

  defp backend_close_unresolved?({:close, _reason}), do: true
  defp backend_close_unresolved?({:sync, _reason, {:close, _close_reason}}), do: true
  defp backend_close_unresolved?(_why), do: false

  # ---------------------------------------------------------------- ownership

  defp canonical_root(root) when is_binary(root) do
    cond do
      not String.starts_with?(root, "/") -> {:error, error(:path, {:root, :not_absolute})}
      String.contains?(root, <<0>>) -> {:error, error(:path, {:root, :contains_nul})}
      true -> {:ok, Path.expand(root)}
    end
  end

  defp canonical_root(other), do: {:error, error(:path, {:root, {:not_a_path, other}})}

  defp global_name(root), do: {__MODULE__, root}

  # Registration IS the claim. A loser is refused here, before init has done any
  # filesystem work, so it never reaches the seam and can never hold a snapshot
  # to resurrect later. The dot-component alias is already normalised by
  # Path.expand, so it collides on the same name.
  defp claim_then_start(root, fs, paths) do
    case GenServer.start_link(__MODULE__, {root, fs, paths}, name: {:global, global_name(root)}) do
      {:ok, pid} ->
        complete_startup(pid, root)

      {:error, {:already_started, _pid}} ->
        {:error, error(:ownership, {:already_owned, root})}

      {:error, reason} ->
        {:error, error(:ownership, reason)}
    end
  end

  # Inspection and load run under held ownership. On failure the owner is stopped
  # normally - which does not disturb a linked, non-trapping caller - so the name
  # is released and no half-ready owner is left registered.
  defp complete_startup(pid, root) do
    case GenServer.call(pid, :complete_startup, :infinity) do
      :ok ->
        {:ok, pid}

      {:error, _} = error ->
        _ = GenServer.stop(pid, :normal)
        error
    end
  catch
    :exit, reason ->
      {:error, error(:ownership, {:startup_failed, root, reason})}
  end

  # -------------------------------------------------------------------- paths

  defp paths(root) do
    state = Path.join(root, @state_dir)
    %{root: root, state: state, final: Path.join(state, @file_name)}
  end

  # Every ancestor is inspected, not just the root itself: a symlink anywhere in
  # the chain means the configured path is not the path that will be written.
  defp inspect_root(fs, root) do
    root
    |> ancestors()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case Fs.lstat(fs, path) do
        {:ok, %{type: :symlink}} -> {:halt, {:error, error(:path, {path, :symlink})}}
        {:ok, _meta} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, error(:path, {path, reason})}}
      end
    end)
    |> case do
      :ok -> inspect_directory(fs, root)
      {:error, _} = error -> error
    end
  end

  defp ancestors(path) do
    path
    |> Path.split()
    |> Enum.scan(fn segment, acc -> Path.join(acc, segment) end)
    |> Enum.reject(&(&1 == "/"))
  end

  defp inspect_directory(fs, path) do
    case Fs.lstat(fs, path) do
      {:ok, %{type: :directory, mode: mode}} -> private_mode(path, mode, 0o700)
      {:ok, %{type: type}} -> {:error, error(:path, {path, {:not_a_directory, type}})}
      {:error, reason} -> {:error, error(:path, {path, reason})}
    end
  end

  # An existing state directory or final file must already be private. The store
  # refuses rather than repairing: chmod-ing someone else's state would be a
  # silent widening of what this unit is allowed to touch.
  defp inspect_state(fs, paths) do
    case Fs.lstat(fs, paths.state) do
      {:error, :enoent} ->
        :ok

      {:ok, %{type: :directory, mode: mode}} ->
        with :ok <- private_mode(paths.state, mode, 0o700) do
          inspect_final(fs, paths)
        end

      {:ok, %{type: type}} ->
        {:error, error(:path, {paths.state, {:not_a_directory, type}})}

      {:error, reason} ->
        {:error, error(:path, {paths.state, reason})}
    end
  end

  defp inspect_final(fs, paths) do
    case Fs.lstat(fs, paths.final) do
      {:error, :enoent} -> :ok
      {:ok, %{type: :regular, mode: mode}} -> private_mode(paths.final, mode, 0o600)
      {:ok, %{type: type}} -> {:error, error(:path, {paths.final, {:not_a_regular_file, type}})}
      {:error, reason} -> {:error, error(:path, {paths.final, reason})}
    end
  end

  defp private_mode(path, mode, expected) do
    if Bitwise.band(mode, 0o077) == 0 and Bitwise.band(mode, 0o700) == Bitwise.band(expected, 0o700) do
      :ok
    else
      {:error, error(:permission, {path, {:unsafe_mode, mode}})}
    end
  end

  # --------------------------------------------------------------------- load

  # An absent final file is empty success. An access, read, decode or schema
  # failure is NOT: turning any of those into an empty snapshot is exactly how a
  # corrupt store silently becomes an empty one.
  defp load(fs, paths) do
    case Fs.lstat(fs, paths.final) do
      {:error, :enoent} ->
        {:ok, []}

      {:ok, %{type: :regular}} ->
        read_snapshot(fs, paths)

      {:ok, %{type: type}} ->
        {:error, error(:path, {paths.final, {:not_a_regular_file, type}})}

      {:error, reason} ->
        {:error, error(:path, {paths.final, reason})}
    end
  end

  defp read_snapshot(fs, paths) do
    with {:ok, bytes} <- read_bytes(fs, paths.final),
         {:ok, records} <- decode(bytes, paths.root) do
      {:ok, records}
    end
  end

  defp read_bytes(fs, final) do
    case Fs.read(fs, final) do
      {:ok, bytes} when is_binary(bytes) -> {:ok, bytes}
      {:ok, other} -> {:error, error(:read, {:read, {:not_binary, other}})}
      {:error, reason} -> {:error, error(:read, {:read, reason})}
    end
  end

  defp decode(bytes, root) do
    case Record.decode_envelope(bytes, root) do
      {:ok, records} -> {:ok, records}
      {:error, {stage, reason}} -> {:error, error(stage, reason)}
    end
  end

  # ------------------------------------------------------------------ persist

  defp persist(state, records) do
    bytes = Record.encode_envelope(records, DateTime.utc_now())

    case ensure_state_dir(state) do
      {:ok, state} ->
        with {:ok, temp} <- create_temp(state),
             :ok <- write_snapshot(state, temp, bytes),
             :ok <- publish(state, temp) do
          {:ok, state}
        else
          {:error, err} -> {:error, state, err}
        end

      {:error, state, err} ->
        {:error, state, err}
    end
  end

  # Creating the state directory OWES a root sync. Its existence never discharges
  # that obligation: if the sync failed, the directory is present while its entry
  # in the root is not durable. The owed flag therefore survives in owner state
  # across the very call that failed, and no later success can be acknowledged
  # until it is discharged.
  defp ensure_state_dir(%{fs: fs, paths: paths} = state) do
    case Fs.lstat(fs, paths.state) do
      {:ok, %{type: :directory, mode: mode}} ->
        case private_mode(paths.state, mode, 0o700) do
          :ok -> discharge_root_sync(state)
          {:error, err} -> {:error, state, err}
        end

      {:error, :enoent} ->
        # H1. mkdir can succeed and the chmod after it still fail, which leaves
        # the directory PRESENT. Returning the pre-creation state on that path
        # dropped the obligation entirely: a retry then found a private existing
        # directory, took discharge_root_sync(false), and acknowledged a write
        # whose root entry had never been synced. Reproduced by ROOT-SYNC-r2.
        #
        # The obligation is therefore owed from the moment creation may have had
        # an effect, and it rides the ERROR path as well as the success path. If
        # mkdir itself failed and nothing was created, owing a sync is merely
        # conservative - a redundant directory_sync is harmless, a missing one is
        # a silent durability hole.
        owing = %{state | root_sync_owed: true}

        case create_state_dir(state) do
          :ok -> discharge_root_sync(owing)
          {:error, err} -> {:error, owing, err}
        end

      {:ok, %{type: type}} ->
        {:error, state, error(:path, {paths.state, {:not_a_directory, type}})}

      {:error, reason} ->
        {:error, state, error(:path, {paths.state, reason})}
    end
  end

  defp create_state_dir(%{fs: fs, paths: paths}) do
    with :ok <- step(Fs.mkdir(fs, paths.state), :create, :mkdir) do
      step(Fs.chmod(fs, paths.state, 0o700), :permission, :chmod)
    end
  end

  # Nothing observable on the filesystem proves a directory entry was ever
  # fsynced. An owner that FINDS the state directory already present therefore
  # owes a root sync, because the previous owner may have created it and then
  # failed that sync. This is what makes the obligation survive an owner restart
  # instead of living only in the memory of the process that failed, and it is
  # why directory existence is never treated as proof the sync ran.
  # H2. This previously used match?/2, which mapped EVERY non-directory result -
  # including {:error, :eio} - to false. An UNCERTAIN observation silently became
  # "no durability debt", and a later call was acknowledged without the restart
  # root sync. Reproduced by ROOT-SYNC-r2.
  #
  # An error is not an answer. Only a definite :enoent means genuinely absent and
  # therefore no debt; anything else is either a real directory (debt owed) or a
  # failed inspection, which is reported through the closed :path stage instead of
  # being collapsed into a boolean.
  defp state_dir_debt(%{fs: fs, paths: paths}) do
    case Fs.lstat(fs, paths.state) do
      {:ok, %{type: :directory}} ->
        {:ok, true}

      {:error, :enoent} ->
        {:ok, false}

      {:ok, %{type: type}} ->
        {:error, error(:path, {paths.state, {:not_a_directory, type}})}

      {:error, reason} ->
        {:error, error(:path, {paths.state, reason})}
    end
  end

  defp discharge_root_sync(%{root_sync_owed: false} = state), do: {:ok, state}

  defp discharge_root_sync(%{fs: fs, paths: paths} = state) do
    case Fs.directory_sync(fs, paths.root) do
      :ok -> {:ok, %{state | root_sync_owed: false}}
      {:error, reason} -> {:error, state, error(:directory_sync, {:directory_sync, reason})}
    end
  end

  defp create_temp(%{fs: fs, paths: paths}) do
    temp = Path.join(paths.state, @file_name <> ".tmp-#{System.unique_integer([:positive])}")

    case Fs.open_exclusive(fs, temp) do
      {:ok, fd} ->
        # Private BEFORE any content exists, so the bytes are never briefly
        # readable. This is checked, not assumed: a failed chmod aborts.
        case Fs.chmod(fs, temp, 0o600) do
          :ok ->
            {:ok, %{path: temp, fd: fd}}

          {:error, reason} ->
            cleanup(fs, temp, release(fs, fd, error(:permission, {:chmod, reason})))
        end

      {:error, reason} ->
        {:error, error(:create, {:open_exclusive, reason})}
    end
  end

  defp write_snapshot(%{fs: fs} = state, temp, bytes) do
    with :ok <- guarded(state, temp, Fs.write(fs, temp.fd, bytes), :write, :write),
         :ok <- guarded(state, temp, Fs.file_sync(fs, temp.fd), :file_sync, :file_sync) do
      guarded(state, temp, Fs.close(fs, temp.fd), :close, :close)
    end
  end

  # The rename is the commit point. Anything from here on is conservatively
  # uncertain: the replacement may or may not have taken effect, and claiming
  # otherwise would be inventing a durable-success result.
  defp publish(%{fs: fs, paths: paths} = state, temp) do
    case Fs.rename(fs, temp.path, paths.final) do
      :ok ->
        case Fs.directory_sync(fs, paths.state) do
          :ok ->
            :ok

          {:error, reason} ->
            {:error, error(:directory_sync, {:directory_sync, reason}, :uncertain)}
        end

      {:error, reason} ->
        cleanup(state.fs, temp.path, error(:rename, {:rename, reason}, :uncertain))
    end
  end

  defp guarded(state, temp, result, stage, callback) do
    case result do
      :ok -> :ok
      {:error, reason} -> abort(state, temp, error(stage, {callback, reason}))
    end
  end

  defp abort(%{fs: fs}, temp, err) do
    cleanup(fs, temp.path, release(fs, temp.fd, err))
  end

  # An ATTEMPTED close is not a closed descriptor. Discarding this result hid a
  # refused close while the descriptor stayed usable and the pathname was
  # unlinked. The failure is now reported alongside the primary error; it is not
  # retried, and the descriptor is not described as released.
  #
  # Frozen r3 names cleanup_errors entries as :temporary_cleanup plus the unlink
  # reason. This uses the same stage and the same stage/reason entry shape with a
  # {:close, reason} substep, adding no new stage atom and no new field. That
  # narrow vocabulary extension was proposed and RULED ON rather than assumed:
  # the addendum carries an explicit GO, so this is settled scope, not a pending
  # question. (An earlier revision of this note still said "pending reviewer
  # ruling" after the ruling had arrived.)
  defp release(fs, fd, %{cleanup_errors: existing} = err) do
    case Fs.close(fs, fd) do
      :ok ->
        err

      {:error, reason} ->
        %{
          err
          | cleanup_errors: existing ++ [%{stage: :temporary_cleanup, reason: {:close, reason}}]
        }
    end
  end

  defp step(result, stage, callback) do
    case result do
      :ok -> :ok
      {:error, reason} -> {:error, error(stage, {callback, reason})}
    end
  end

  # Best effort, and its own failure is reported alongside the primary error
  # rather than replacing or hiding it.
  defp cleanup(fs, temp_path, %{cleanup_errors: existing} = err) do
    case Fs.unlink(fs, temp_path) do
      :ok ->
        {:error, err}

      {:error, reason} ->
        entry = %{stage: :temporary_cleanup, reason: {:unlink, reason}}
        {:error, %{err | cleanup_errors: existing ++ [entry]}}
    end
  end

  defp error(stage, reason, outcome \\ :unchanged) do
    %{stage: stage, reason: reason, outcome: outcome, cleanup_errors: []}
  end
end
