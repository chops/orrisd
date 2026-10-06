defmodule AiPair.Delivery.PayloadStore do
  @moduledoc """
  Attempt-bound prompt payload objects for queued receipted sends (NS-15.G.003 S1).

  Owned and serialized by `AiPair.Delivery.ReceiptStore`; never shared. An object is named
  `<msg_id>.<attempt>.<sha256 hex>.payload` from validated receipt fields only, published by
  exclusive temp create, fsync and hard link (never overwritten), and removed only after its
  attempt's terminal receipt is durable. S2 keeps (and counts) only the objects of boot-restored
  queued attempts, whose bytes were verified before boot cleanup (`verified?/4`).

  Threat model (S1 RED design r3): the directory has the receipt log's trust boundary. The
  directory checks DETECT a replacement already present and stop further work; they do not
  close a race with a concurrent same-uid swap of the directory or a parent (OTP has no
  directory-handle file API), and a later check cannot undo an operation already performed.
  An object is read only when its lstat and the fstat of the opened handle name one inode.

  Capacity accounting fails closed: when a cleanup or post-link step fails, an entry the
  counts do not describe may remain, so the store disables itself (every later publication
  is refused payload_store_unavailable) and never frees count or bytes it cannot prove free.
  Only the next boot's rescan re-enables it.
  """

  alias AiPair.Delivery.Fs

  @default_objects 256
  @default_bytes 67_108_864
  @max_object_bytes 524_288
  @name ~r/\A(snd_[0-9a-f]{64})\.([1-9][0-9]*)\.([0-9a-f]{64})\.payload\z/

  defstruct [:fs, :dir, :pin, :uid, count: 0, bytes: 0, objects: %{}, limits: {256, 67_108_864}]

  @spec limits() :: {pos_integer(), pos_integer()}
  def limits, do: {@default_objects, @default_bytes}

  @doc """
  Open the payload directory and clean it at boot. `keep` decides, per parsed object name
  `{msg_id, attempt, hash}`, whether the object belongs to a restored queued attempt.
  An unsafe directory disables the store and is left untouched.
  """
  def boot(fs, inbox, log_path, opts, keep) do
    dir = Path.join([inbox, "delivery", "payloads"])
    {default_n, default_b} = limits()

    store = %__MODULE__{
      fs: fs,
      dir: dir,
      limits:
        {Keyword.get(opts, :payload_limit_objects, default_n),
         Keyword.get(opts, :payload_limit_bytes, default_b)}
    }

    # The daemon's own uid is the owner of the receipt log it just opened.
    with {:ok, %File.Stat{uid: uid}} <- Fs.lstat(fs, log_path),
         :ok <- ensure_dir(fs, dir),
         {:ok, stat} <- Fs.lstat(fs, dir),
         :ok <- safe_dir(stat, uid) do
      pinned = %{store | pin: {stat.major_device, stat.inode}, uid: uid}
      clean(pinned, keep)
    else
      _ -> store
    end
  end

  @doc "Publish `bytes` for `view` (an admitted attempt). Returns {:ok, store} or {:error, kind, store}."
  def publish(%__MODULE__{} = store, view, bytes, hash_of_bytes) do
    size = byte_size(bytes)
    {max_n, max_b} = store.limits

    cond do
      hash_of_bytes != view.payload_hash -> {:error, :payload_store_unavailable, store}
      is_nil(store.pin) -> {:error, :payload_store_unavailable, store}
      store.count + 1 > max_n or store.bytes + size > max_b -> {:error, :payload_store_full, store}
      true -> publish_checked(store, view, bytes, size)
    end
  end

  @doc "Remove the object of a terminal attempt, after its terminal receipt is durable."
  def release(%__MODULE__{pin: nil} = store, _view), do: store

  def release(%__MODULE__{} = store, view) do
    key = {view.message_id, view.delivery_attempt}

    case Map.fetch(store.objects, key) do
      {:ok, {name, size}} ->
        path = Path.join(store.dir, name)

        with true <- dir_unchanged?(store),
             :ok <- removed(Fs.unlink(store.fs, path)),
             :ok <- Fs.dir_sync(store.fs, path) do
          forget(store, key, size)
        else
          # The object may remain: keep its accounting and stop publishing until a reboot.
          _ -> disable(store)
        end

      :error ->
        store
    end
  end

  @doc """
  Restore predicate (c): the exact object of `view`'s attempt exists in a safe payload
  directory, passes the S1 path-safety and read checks, and its bytes hash to payload_hash.
  Read-only.
  """
  def verified?(fs, inbox, log_path, view) do
    dir = Path.join([inbox, "delivery", "payloads"])

    with {:ok, %File.Stat{uid: uid}} <- Fs.lstat(fs, log_path),
         {:ok, stat} <- Fs.lstat(fs, dir),
         :ok <- safe_dir(stat, uid),
         {:ok, bytes} <- read_verified(fs, Path.join(dir, object_name(view)), uid) do
      AiPair.Delivery.Payload.hash(AiPair.Delivery.Payload.new(bytes)) == view.payload_hash
    else
      _ -> false
    end
  end

  @doc "The verified read of one object: {:ok, bytes} or {:error, reason}."
  def read_verified(fs, path, uid) do
    with {:ok, %File.Stat{} = before} <- Fs.lstat(fs, path),
         :ok <- own_regular(before, uid),
         true <- before.size <= @max_object_bytes,
         {:ok, fd} <- Fs.open_read(fs, path) do
      result =
        with {:ok, opened} <- Fs.fstat(fs, fd),
             true <- {opened.major_device, opened.inode} == {before.major_device, before.inode} do
          Fs.read_handle(fs, fd)
        else
          _ -> {:error, :object_changed}
        end

      _ = Fs.close(fs, fd)
      result
    else
      _ -> {:error, :object_unverified}
    end
  end

  @doc "The exact object path of a restored registry entry (msg_id, attempt, payload_hash)."
  def object_path(%__MODULE__{dir: dir}, entry) do
    view = %{
      message_id: entry.msg_id,
      delivery_attempt: entry.attempt,
      payload_hash: entry.payload_hash
    }

    Path.join(dir, object_name(view))
  end

  # ----- internals -----

  defp ensure_dir(fs, dir) do
    case Fs.lstat(fs, dir) do
      {:ok, _} -> :ok
      {:error, :enoent} -> Fs.mkdir_p(fs, dir, 0o700)
      other -> other
    end
  end

  defp safe_dir(%File.Stat{type: :directory, mode: mode, uid: uid}, uid)
       when Bitwise.band(mode, 0o777) == 0o700,
       do: :ok

  defp safe_dir(_stat, _uid), do: {:error, :unsafe_payload_dir}

  defp dir_unchanged?(store) do
    case Fs.lstat(store.fs, store.dir) do
      {:ok, stat} ->
        safe_dir(stat, store.uid) == :ok and {stat.major_device, stat.inode} == store.pin

      _ ->
        false
    end
  end

  defp publish_checked(store, view, bytes, size) do
    if dir_unchanged?(store) do
      name = object_name(view)
      final = Path.join(store.dir, name)

      temp =
        Path.join(store.dir, ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower))

      case write_temp(store, temp, bytes) do
        :ok -> link_and_sync(store, temp, final, name, view, bytes, size)
        :error -> {:error, :payload_store_unavailable, store}
        :uncertain -> {:error, :payload_store_unavailable, disable(store)}
      end
    else
      {:error, :payload_store_unavailable, disable(store)}
    end
  end

  defp write_temp(store, temp, bytes) do
    case Fs.open_exclusive(store.fs, temp) do
      {:ok, fd} ->
        result =
          with :ok <- Fs.chmod(store.fs, temp, 0o600),
               {:ok, stat} <- Fs.fstat(store.fs, fd),
               :ok <- own_regular(stat, store.uid),
               :ok <- Fs.write(store.fs, fd, bytes),
               :ok <- Fs.sync(store.fs, fd) do
            Fs.close(store.fs, fd)
          else
            _ ->
              _ = Fs.close(store.fs, fd)
              :failed
          end

        cond do
          result == :ok -> :ok
          # A temp that cannot be removed is an entry the counts do not describe.
          removed(Fs.unlink(store.fs, temp)) == :ok -> :error
          true -> :uncertain
        end

      _ ->
        :error
    end
  end

  defp own_regular(%File.Stat{type: :regular, mode: mode, uid: uid, links: 1}, uid)
       when Bitwise.band(mode, 0o777) == 0o600,
       do: :ok

  defp own_regular(_stat, _uid), do: {:error, :unsafe_temp}

  defp link_and_sync(store, temp, final, name, view, bytes, size) do
    # :refused is a final name that is not ours (other bytes, a symlink, a directory): nothing
    # was linked. Any other link error leaves it unknown whether the final name now exists.
    linked =
      case Fs.link(store.fs, temp, final) do
        :ok -> :ok
        {:error, :eexist} -> if same_object?(store, final, bytes), do: :ok, else: :refused
        _ -> :uncertain
      end

    with :ok <- linked,
         :ok <- Fs.unlink(store.fs, temp),
         :ok <- Fs.dir_sync(store.fs, final) do
      key = {view.message_id, view.delivery_attempt}
      objects = Map.put(store.objects, key, {name, size})
      {:ok, %{store | objects: objects, count: store.count + 1, bytes: store.bytes + size}}
    else
      _ ->
        if linked == :refused and removed(Fs.unlink(store.fs, temp)) == :ok do
          {:error, :payload_store_unavailable, store}
        else
          # A linked but unsynced or uncounted final object, or a temp left behind.
          {:error, :payload_store_unavailable, disable(store)}
        end
    end
  end

  # lstat, open, fstat: the same inode, a regular 0600 file of ours, then the bytes.
  defp same_object?(store, path, bytes) do
    with {:ok, %File.Stat{} = before} <- Fs.lstat(store.fs, path),
         :ok <- own_regular(before, store.uid),
         true <- before.size <= @max_object_bytes,
         {:ok, fd} <- Fs.open_read(store.fs, path) do
      result =
        with {:ok, opened} <- Fs.fstat(store.fs, fd),
             true <- {opened.major_device, opened.inode} == {before.major_device, before.inode},
             {:ok, existing} <- Fs.read_handle(store.fs, fd) do
          existing == bytes
        else
          _ -> false
        end

      _ = Fs.close(store.fs, fd)
      result
    else
      _ -> false
    end
  end

  defp clean(store, keep) do
    case Fs.list(store.fs, store.dir) do
      {:ok, names} ->
        removable = Enum.filter(names, &removable?(&1, keep))
        unlinked = Enum.map(removable, &removed(Fs.unlink(store.fs, Path.join(store.dir, &1))))

        synced =
          if removable == [], do: :ok, else: Fs.dir_sync(store.fs, Path.join(store.dir, "."))

        # A store's counts are claimed only when every removal is durable. Kept (restored)
        # objects count against the limits from boot.
        if Enum.all?(unlinked, &(&1 == :ok)) and synced == :ok,
          do: count_kept(store, names -- removable),
          else: disable(store)

      _ ->
        disable(store)
    end
  end

  # Leftover temps always go. An object goes unless it belongs to a restored queued attempt.
  # Any other entry is not ours and is left alone.
  defp removable?(entry, keep) do
    cond do
      String.starts_with?(entry, ".tmp-") ->
        true

      match = Regex.run(@name, entry, capture: :all_but_first) ->
        [id, attempt, hex] = match
        not keep.({id, String.to_integer(attempt), "sha256:" <> hex})

      true ->
        false
    end
  end

  # Every kept object is counted from its own lstat. One that cannot be measured is an entry
  # the counts would not describe, so the store disables itself (fail closed), as in S1.
  defp count_kept(store, names) do
    Enum.reduce_while(names, store, fn name, acc ->
      case Regex.run(@name, name, capture: :all_but_first) do
        [id, attempt, _hex] ->
          case Fs.lstat(acc.fs, Path.join(acc.dir, name)) do
            {:ok, %File.Stat{size: size}} ->
              key = {id, String.to_integer(attempt)}

              {:cont,
               %{
                 acc
                 | objects: Map.put(acc.objects, key, {name, size}),
                   count: acc.count + 1,
                   bytes: acc.bytes + size
               }}

            _ ->
              {:halt, disable(acc)}
          end

        _ ->
          {:cont, acc}
      end
    end)
  end

  # An entry already absent is removed.
  defp removed(:ok), do: :ok
  defp removed({:error, :enoent}), do: :ok
  defp removed(other), do: other

  defp disable(store), do: %{store | pin: nil}

  defp forget(store, key, size),
    do: %{
      store
      | objects: Map.delete(store.objects, key),
        count: store.count - 1,
        bytes: store.bytes - size
    }

  defp object_name(view) do
    "sha256:" <> hex = view.payload_hash
    "#{view.message_id}.#{view.delivery_attempt}.#{hex}.payload"
  end
end
