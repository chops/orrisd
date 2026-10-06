defmodule AiPair.Delivery.Fs do
  @moduledoc """
  The filesystem operations the delivery receipt log performs, as an injectable seam.

  The receipt log is the daemon's only evidence that bytes reached a pane, and the
  orchestrator is allowed to send a prompt only because a receipt was durable *before*
  the paste. That ordering cannot be observed from outside: reading the file after a
  successful call proves the bytes are there now, not that they were fsynced before the
  caller was told so. Refusing the syscall is the only way to prove it, so every
  operation the log performs goes through this behaviour and the tests supply a
  fault-injecting implementation.

  This is deliberately the receipt log's own vocabulary rather than a general filesystem
  abstraction. Orris has a sibling `Journal.Fs` for its journal; the two
  products are separate deliverables and the shared-fixture byte-identical rule governs
  wire fixtures, not internal seams, so neither depends on the other.

  Implementations return errors; they never raise. A handle is `{module, state}` so an
  implementation may carry state without a process registry.
  """

  @type t :: {module(), term()}
  @type fd :: term()
  @type posix :: :file.posix() | term()

  @doc "Create a directory and its parents, with the given mode applied to created leaves."
  @callback mkdir_p(term(), Path.t(), non_neg_integer()) :: :ok | {:error, posix()}

  @doc "Open a path for appending. The file is created if absent."
  @callback open(term(), Path.t()) :: {:ok, fd()} | {:error, posix()}

  @doc "Append exactly these bytes. A partial write is an error, never a short success."
  @callback write(term(), fd(), iodata()) :: :ok | {:error, posix()}

  @doc "fsync the file. This is what makes an append durable."
  @callback sync(term(), fd()) :: :ok | {:error, posix()}

  @callback close(term(), fd()) :: :ok | {:error, posix()}

  @doc "Set the mode of a path. Used to keep the log 0600 and its directory 0700."
  @callback chmod(term(), Path.t(), non_neg_integer()) :: :ok | {:error, posix()}

  @doc """
  fsync the directory containing a path.

  Required when a directory entry changes -- creating the log -- because a file whose
  entry is unsynced can vanish entirely on power loss. Not required for an ordinary
  append, which changes no entry.
  """
  @callback dir_sync(term(), Path.t()) :: :ok | {:error, posix()}

  @doc "Truncate a path to a byte length and fsync it. Used to repair one torn tail."
  @callback truncate(term(), Path.t(), non_neg_integer()) :: :ok | {:error, posix()}

  @callback read(term(), Path.t()) :: {:ok, binary()} | {:error, posix()}

  @callback exists?(term(), Path.t()) :: boolean()

  @doc "Create a new file for writing; fails with :eexist if any entry (a symlink included) exists."
  @callback open_exclusive(term(), Path.t()) :: {:ok, fd()} | {:error, posix()}

  @doc "Open an existing file read-only."
  @callback open_read(term(), Path.t()) :: {:ok, fd()} | {:error, posix()}

  @doc "Read every byte of an open handle."
  @callback read_handle(term(), fd()) :: {:ok, binary()} | {:error, posix()}

  @doc "Stat the OPEN handle itself (fstat): the file it refers to, whatever its path now names."
  @callback fstat(term(), fd()) :: {:ok, File.Stat.t()} | {:error, posix()}

  @doc "Stat a path without following a final symlink (lstat)."
  @callback lstat(term(), Path.t()) :: {:ok, File.Stat.t()} | {:error, posix()}

  @doc "Create a hard link; fails with :eexist if the new name exists."
  @callback link(term(), Path.t(), Path.t()) :: :ok | {:error, posix()}

  @doc "Remove a directory entry; a symlink entry is removed, never followed."
  @callback unlink(term(), Path.t()) :: :ok | {:error, posix()}

  @doc "The entry names of a directory."
  @callback list(term(), Path.t()) :: {:ok, [String.t()]} | {:error, posix()}

  @spec mkdir_p(t(), Path.t(), non_neg_integer()) :: :ok | {:error, posix()}
  def mkdir_p({mod, state}, dir, mode), do: mod.mkdir_p(state, dir, mode)

  @spec open(t(), Path.t()) :: {:ok, fd()} | {:error, posix()}
  def open({mod, state}, path), do: mod.open(state, path)

  @spec write(t(), fd(), iodata()) :: :ok | {:error, posix()}
  def write({mod, state}, fd, data), do: mod.write(state, fd, data)

  @spec sync(t(), fd()) :: :ok | {:error, posix()}
  def sync({mod, state}, fd), do: mod.sync(state, fd)

  @spec close(t(), fd()) :: :ok | {:error, posix()}
  def close({mod, state}, fd), do: mod.close(state, fd)

  @spec chmod(t(), Path.t(), non_neg_integer()) :: :ok | {:error, posix()}
  def chmod({mod, state}, path, mode), do: mod.chmod(state, path, mode)

  @spec dir_sync(t(), Path.t()) :: :ok | {:error, posix()}
  def dir_sync({mod, state}, path), do: mod.dir_sync(state, path)

  @spec truncate(t(), Path.t(), non_neg_integer()) :: :ok | {:error, posix()}
  def truncate({mod, state}, path, bytes), do: mod.truncate(state, path, bytes)

  @spec read(t(), Path.t()) :: {:ok, binary()} | {:error, posix()}
  def read({mod, state}, path), do: mod.read(state, path)

  @spec exists?(t(), Path.t()) :: boolean()
  def exists?({mod, state}, path), do: mod.exists?(state, path)

  @spec open_exclusive(t(), Path.t()) :: {:ok, fd()} | {:error, posix()}
  def open_exclusive({mod, state}, path), do: mod.open_exclusive(state, path)

  @spec open_read(t(), Path.t()) :: {:ok, fd()} | {:error, posix()}
  def open_read({mod, state}, path), do: mod.open_read(state, path)

  @spec read_handle(t(), fd()) :: {:ok, binary()} | {:error, posix()}
  def read_handle({mod, state}, fd), do: mod.read_handle(state, fd)

  @spec fstat(t(), fd()) :: {:ok, File.Stat.t()} | {:error, posix()}
  def fstat({mod, state}, fd), do: mod.fstat(state, fd)

  @spec lstat(t(), Path.t()) :: {:ok, File.Stat.t()} | {:error, posix()}
  def lstat({mod, state}, path), do: mod.lstat(state, path)

  @spec link(t(), Path.t(), Path.t()) :: :ok | {:error, posix()}
  def link({mod, state}, existing, new), do: mod.link(state, existing, new)

  @spec unlink(t(), Path.t()) :: :ok | {:error, posix()}
  def unlink({mod, state}, path), do: mod.unlink(state, path)

  @spec list(t(), Path.t()) :: {:ok, [String.t()]} | {:error, posix()}
  def list({mod, state}, dir), do: mod.list(state, dir)
end
