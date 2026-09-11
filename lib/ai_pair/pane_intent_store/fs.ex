defmodule AiPair.PaneIntentStore.Fs do
  @moduledoc """
  Injected filesystem seam for `AiPair.PaneIntentStore`.

  Every filesystem effect the store performs goes through this seam. Only the
  allowlisted `AiPair.PaneIntentStore.Fs.SystemFs` backend calls `File`/`:file`
  directly, which is what lets a test double observe and fail each operation
  independently.

  This is deliberately a second seam rather than a reuse of `AiPair.Delivery.Fs`,
  which is the receipt log's own vocabulary: it has no `rename`, no exclusive
  creation, no `unlink` and no `lstat`, and the pane-intent durability sequence
  needs all four.

  ## Handles

  A seam value is a `{module, state}` handle. The module implements this
  behaviour and the state is threaded back to it as the first argument, so one
  backend module can serve many independent instances. The store never inspects
  the state.

  ## Contract

  Every callback returns `:ok`/`{:ok, value}` or `{:error, reason}`; no callback
  signals by raising, and no effect bypasses the seam. `open_exclusive/2` refuses
  an existing path. `write/3` succeeding means every byte was written.
  `directory_sync/2` syncs exactly the directory it is given and never an
  inferred parent. A backend implementing one semantic callback with several
  internal operations must check each of them - `directory_sync/2` checks its
  open, its sync and its close - so a failure cannot be silently discarded.
  """

  @typedoc "Opaque per-instance backend state, threaded back to the module."
  @type state :: term()

  @typedoc "A seam value: the implementing module plus its state."
  @type handle :: {module(), state()}

  @typedoc "An open file handle, owned by the backend."
  @type fd :: term()

  @type reason :: term()

  @typedoc "Metadata `lstat/2` reports. `mode` is the permission bits only."
  @type meta :: %{type: atom(), mode: non_neg_integer()}

  @callback lstat(state(), Path.t()) :: {:ok, meta()} | {:error, reason()}
  @callback mkdir(state(), Path.t()) :: :ok | {:error, reason()}
  @callback chmod(state(), Path.t(), non_neg_integer()) :: :ok | {:error, reason()}
  @callback open_exclusive(state(), Path.t()) :: {:ok, fd()} | {:error, reason()}
  @callback read(state(), Path.t()) :: {:ok, binary()} | {:error, reason()}
  @callback write(state(), fd(), iodata()) :: :ok | {:error, reason()}
  @callback file_sync(state(), fd()) :: :ok | {:error, reason()}
  @callback close(state(), fd()) :: :ok | {:error, reason()}
  @callback rename(state(), Path.t(), Path.t()) :: :ok | {:error, reason()}
  @callback directory_sync(state(), Path.t()) :: :ok | {:error, reason()}
  @callback unlink(state(), Path.t()) :: :ok | {:error, reason()}

  @doc "The default seam: the real filesystem, with no per-instance state."
  @spec default() :: handle()
  def default, do: {AiPair.PaneIntentStore.Fs.SystemFs, nil}

  @spec lstat(handle(), Path.t()) :: {:ok, meta()} | {:error, reason()}
  def lstat({m, s}, path), do: m.lstat(s, path)

  @spec mkdir(handle(), Path.t()) :: :ok | {:error, reason()}
  def mkdir({m, s}, path), do: m.mkdir(s, path)

  @spec chmod(handle(), Path.t(), non_neg_integer()) :: :ok | {:error, reason()}
  def chmod({m, s}, path, mode), do: m.chmod(s, path, mode)

  @spec open_exclusive(handle(), Path.t()) :: {:ok, fd()} | {:error, reason()}
  def open_exclusive({m, s}, path), do: m.open_exclusive(s, path)

  @spec read(handle(), Path.t()) :: {:ok, binary()} | {:error, reason()}
  def read({m, s}, path), do: m.read(s, path)

  @spec write(handle(), fd(), iodata()) :: :ok | {:error, reason()}
  def write({m, s}, fd, data), do: m.write(s, fd, data)

  @spec file_sync(handle(), fd()) :: :ok | {:error, reason()}
  def file_sync({m, s}, fd), do: m.file_sync(s, fd)

  @spec close(handle(), fd()) :: :ok | {:error, reason()}
  def close({m, s}, fd), do: m.close(s, fd)

  @spec rename(handle(), Path.t(), Path.t()) :: :ok | {:error, reason()}
  def rename({m, s}, from, to), do: m.rename(s, from, to)

  @spec directory_sync(handle(), Path.t()) :: :ok | {:error, reason()}
  def directory_sync({m, s}, dir), do: m.directory_sync(s, dir)

  @spec unlink(handle(), Path.t()) :: :ok | {:error, reason()}
  def unlink({m, s}, path), do: m.unlink(s, path)
end
