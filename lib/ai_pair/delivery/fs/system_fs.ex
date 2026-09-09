defmodule AiPair.Delivery.SystemFs do
  @moduledoc """
  The real filesystem behind `AiPair.Delivery.Fs`.

  `:file.sync/1` issues `fsync(2)`. On macOS that flushes to the device but does not
  necessarily flush the device's own write cache; `F_FULLFSYNC` would, and is not
  reachable from Erlang without a NIF. This is recorded rather than worked around: the
  guarantee the receipt log actually offers is "the kernel has the bytes before the
  caller is told so", which is what protects against a daemon crash, and it is not
  claimed to survive sudden power loss on that platform.
  """

  @behaviour AiPair.Delivery.Fs

  @spec new() :: AiPair.Delivery.Fs.t()
  def new, do: {__MODULE__, nil}

  @impl true
  def mkdir_p(_state, dir, mode) do
    with :ok <- File.mkdir_p(dir) do
      File.chmod(dir, mode)
    end
  end

  @impl true
  def open(_state, path) do
    :file.open(path, [:append, :raw, :binary])
  end

  @impl true
  def write(_state, fd, data) do
    # `:file.write/2` on a raw fd writes all of the iodata or returns an error; it never
    # reports a short write as success.
    :file.write(fd, data)
  end

  @impl true
  def sync(_state, fd), do: :file.sync(fd)

  @impl true
  def close(_state, fd), do: :file.close(fd)

  @impl true
  def chmod(_state, path, mode), do: File.chmod(path, mode)

  @impl true
  def dir_sync(_state, path) do
    dir = Path.dirname(path)

    case :file.open(dir, [:read, :raw, :binary, :directory]) do
      {:ok, fd} ->
        try do
          :file.sync(fd)
        after
          :file.close(fd)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def truncate(_state, path, bytes) do
    case :file.open(path, [:read, :write, :raw, :binary]) do
      {:ok, fd} ->
        try do
          with {:ok, _} <- :file.position(fd, bytes),
               :ok <- :file.truncate(fd) do
            :file.sync(fd)
          end
        after
          :file.close(fd)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def read(_state, path), do: File.read(path)

  @impl true
  def exists?(_state, path), do: File.exists?(path)
end
