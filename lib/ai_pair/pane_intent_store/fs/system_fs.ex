defmodule AiPair.PaneIntentStore.Fs.SystemFs do
  @moduledoc """
  The real filesystem behind `AiPair.PaneIntentStore.Fs`.

  This is the only module in the store that calls `File`/`:file`. Everything
  else reaches the filesystem through the seam, which is what lets a double
  observe and fail each operation independently.

  ## Durability boundary, stated rather than implied

  `:file.sync/1` issues `fsync(2)`. On macOS that flushes to the device but does
  not necessarily flush the device's own write cache; `F_FULLFSYNC` would, and is
  not reachable from Erlang without a NIF. So the guarantee offered is "the
  kernel has the bytes before the caller is told so", which is what protects
  against a daemon crash. Survival of sudden hardware power loss on that platform
  is NOT claimed.

  ## Two deliberate differences from `AiPair.Delivery.SystemFs`

  That module's `dir_sync/2` takes a file path and syncs its *parent*. This
  seam's `directory_sync/2` syncs exactly the directory it is given, because the
  store must be able to sync the state directory and the root as distinct,
  explicitly named targets.

  That module also closes inside an `after` block, which discards the close
  result. Here open, sync AND close are each checked and the substep is retained
  in the reason, because an unchecked close can drop the very error the sync was
  performed to detect.
  """

  @behaviour AiPair.PaneIntentStore.Fs

  @doc "The seam handle for the real filesystem. Carries no per-instance state."
  @spec new() :: AiPair.PaneIntentStore.Fs.handle()
  def new, do: {__MODULE__, nil}

  @impl true
  def lstat(_state, path) do
    # lstat, not stat: a symlink must be reported as a symlink rather than
    # followed, since the store refuses symlinked state and final paths.
    case File.lstat(path) do
      {:ok, %File.Stat{type: type, mode: mode}} ->
        {:ok, %{type: type, mode: Bitwise.band(mode, 0o777)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def mkdir(_state, path), do: File.mkdir(path)

  @impl true
  def chmod(_state, path, mode), do: File.chmod(path, mode)

  @impl true
  def open_exclusive(_state, path) do
    # `:exclusive` is O_CREAT|O_EXCL: an existing path fails with :eexist rather
    # than being truncated, so the temporary file is always this owner's own.
    :file.open(path, [:write, :exclusive, :raw, :binary])
  end

  @impl true
  def read(_state, path), do: File.read(path)

  @impl true
  def write(_state, fd, data) do
    # `:file.write/2` on a raw fd writes all of the iodata or returns an error;
    # it never reports a short write as success.
    :file.write(fd, data)
  end

  @impl true
  def file_sync(_state, fd), do: :file.sync(fd)

  @impl true
  def close(_state, fd), do: :file.close(fd)

  @impl true
  def rename(_state, from, to), do: :file.rename(from, to)

  @impl true
  def directory_sync(state, directory), do: directory_sync(state, directory, :file)

  @doc """
  The `io` argument is a COMPILED backend injection point, never runtime
  configuration and never an untrusted module selection: the arity-2 callback
  above always passes `:file`, and only test code passes anything else.

  It exists because the sync and close substeps are not inducible against a real
  filesystem - opening a directory read-only and syncing it succeeds - so without
  it their checking would stay a source property instead of a measured one.
  """
  @doc since: "G6"
  def directory_sync(_state, directory, io) do
    case io.open(directory, [:read, :raw, :binary, :directory]) do
      {:ok, fd} ->
        # Sync and close are both performed and both checked. The close still
        # happens when the sync failed, and the sync failure remains the primary
        # one reported. When BOTH fail the close reason is carried alongside it
        # rather than discarded, which the previous shape did.
        sync_result = io.sync(fd)
        close_result = io.close(fd)

        case {sync_result, close_result} do
          {:ok, :ok} ->
            :ok

          {{:error, sync_reason}, {:error, close_reason}} ->
            {:error, {:sync, sync_reason, {:close, close_reason}}}

          {{:error, reason}, :ok} ->
            {:error, {:sync, reason}}

          {:ok, {:error, reason}} ->
            {:error, {:close, reason}}
        end

      {:error, reason} ->
        {:error, {:open, reason}}
    end
  end

  @impl true
  def unlink(_state, path), do: :file.delete(path)
end
