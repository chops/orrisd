defmodule AiPair.Delivery.EffectJournal do
  @moduledoc false
  # NS-15.G.003 S3a: the durable record of gated delivery transactions (scope r12,
  # "Effect journal"). `<inbox>/delivery/effects.jsonl`, mode 0600, one JSON object per
  # line, sha256-chained like the receipt log. Kinds and their exact fields (plus the common
  # schema, v, kind and prev_line_sha256):
  #
  #   begin     marker_id, pane_id, msg_id, attempt, buffer
  #   end       marker_id, code (0..255), cleanup (nil or 0..255)
  #   residual  marker_id, pane_id, msg_id, attempt, buffer (equal to an earlier begin)
  #   retained  the residual fields; written only by compaction, as a sorted prefix
  #
  # A begin without its end is an uncleared marker: its pane is EFFECT_UNRESOLVED. What a
  # restart sees is decided only by the validated bytes present; a torn final line is
  # truncated, any other invalid line refuses with {:effect_journal_corrupt, line_number}
  # and leaves the file byte-unchanged. Open compacts to the canonical form: every
  # retained/residual record as sorted `retained` lines, then every uncleared begin.

  alias AiPair.Delivery.{Fs, ReceiptLog}

  @schema "ai-pair/paste-effect"
  @anchor "sha256:" <> Base.encode16(:crypto.hash(:sha256, ""), case: :lower)
  @max_residuals 256
  @compact_bytes 1_048_576
  @common ~w(schema v kind prev_line_sha256)
  @fields %{
    "begin" => ~w(marker_id pane_id msg_id attempt buffer),
    "end" => ~w(marker_id code cleanup),
    "residual" => ~w(marker_id pane_id msg_id attempt buffer),
    "retained" => ~w(marker_id pane_id msg_id attempt buffer)
  }

  # order: every begin's marker in file order, so compaction keeps uncleared begins in order
  defstruct [:fs, :fd, :path, previous: @anchor, size: 0, open: %{}, residuals: %{}, order: []]

  @type t :: %__MODULE__{}

  @doc false
  def max_residuals, do: @max_residuals

  @spec open(Fs.t(), Path.t()) :: {:ok, t()} | {:error, term()}
  def open(fs, inbox) do
    path = Path.join([inbox, "delivery", "effects.jsonl"])

    with {:ok, bytes} <- read(fs, path),
         {:ok, lines, torn} <- split(bytes),
         {:ok, state} <- validate(lines),
         :ok <- repair(fs, path, byte_size(bytes), torn) do
      compact(%__MODULE__{
        fs: fs,
        path: path,
        open: state.open,
        residuals: state.residuals,
        order: Enum.reverse(state.order)
      })
    end
  end

  @spec close(t()) :: :ok | {:error, term()}
  def close(%__MODULE__{fd: nil}), do: :ok
  def close(%__MODULE__{fs: fs, fd: fd}), do: named(Fs.close(fs, fd), :effect_close_failed)

  @doc "Panes held EFFECT_UNRESOLVED: those with an uncleared begin."
  def unresolved(%__MODULE__{open: open}),
    do: open |> Map.values() |> Enum.map(& &1["pane_id"]) |> Enum.uniq() |> Enum.sort()

  def unresolved?(%__MODULE__{} = j, pane), do: pane in unresolved(j)

  @doc "Every recorded residual, observable across restarts; never claimed deleted."
  def residuals(%__MODULE__{residuals: residuals}) do
    residuals
    |> Map.values()
    |> Enum.sort_by(& &1["marker_id"])
    |> Enum.map(&%{buffer: &1["buffer"], msg_id: &1["msg_id"], attempt: &1["attempt"]})
  end

  def residual_full?(%__MODULE__{residuals: residuals}), do: map_size(residuals) >= @max_residuals

  @doc "Durably record a begin; STARTED only after a successful fsync."
  def begin(%__MODULE__{} = j, pane, msg_id, attempt, buffer) do
    marker = "mk_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    record = %{
      "kind" => "begin",
      "marker_id" => marker,
      "pane_id" => pane,
      "msg_id" => msg_id,
      "attempt" => attempt,
      "buffer" => buffer
    }

    with {:ok, j} <- append(j, record),
         do: {:ok, marker, %{j | open: Map.put(j.open, marker, record), order: j.order ++ [marker]}}
  end

  @doc "Durably record a residual for an open marker (before its end)."
  # Refused, nothing appended, for a second residual of one marker or past the bound, so the
  # journal never holds a record its own boot validator rejects.
  def residual(%__MODULE__{open: open} = j, marker) do
    cond do
      not Map.has_key?(open, marker) ->
        {:error, :unknown_marker}

      Map.has_key?(j.residuals, marker) ->
        {:error, :duplicate_residual}

      residual_full?(j) ->
        {:error, :residual_capacity_full}

      true ->
        record = Map.put(Map.take(open[marker], @fields["residual"]), "kind", "residual")

        with {:ok, j} <- append(j, record),
             do: {:ok, %{j | residuals: Map.put(j.residuals, marker, record)}}
    end
  end

  @doc "Durably record the end of an open marker; compacts above the size threshold."
  # The end is refused, nothing appended, unless it is one the boot validator accepts: a
  # code and cleanup in range, a residual recorded exactly when the cleanup failed.
  def finish(%__MODULE__{open: open} = j, marker, code, cleanup) do
    residual? = Map.has_key?(j.residuals, marker)
    failed_cleanup? = cleanup not in [nil, 0]

    cond do
      not Map.has_key?(open, marker) ->
        {:error, :unknown_marker}

      not (code?(code) and (is_nil(cleanup) or code?(cleanup))) ->
        {:error, :invalid_end}

      residual? != failed_cleanup? ->
        {:error, :inconsistent_end}

      true ->
        record = %{"kind" => "end", "marker_id" => marker, "code" => code, "cleanup" => cleanup}

        with {:ok, j} <- append(j, record) do
          j = %{j | open: Map.delete(j.open, marker)}
          if j.size > @compact_bytes, do: compact(j), else: {:ok, j}
        end
    end
  end

  # ===== validation =====

  defp read(fs, path) do
    case Fs.read(fs, path) do
      {:ok, bytes} when is_binary(bytes) -> {:ok, bytes}
      {:error, :enoent} -> {:ok, ""}
      other -> named(other, :effect_read_failed)
    end
  end

  # complete lines and the byte length of a torn tail (no final newline)
  defp split(bytes) do
    parts = :binary.split(bytes, "\n", [:global])
    {lines, [tail]} = Enum.split(parts, -1)
    {:ok, lines, byte_size(tail)}
  end

  defp validate(lines) do
    initial = %{
      previous: @anchor,
      open: %{},
      residuals: %{},
      ends: MapSet.new(),
      live: false,
      order: []
    }

    lines
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, initial}, fn {line, n}, {:ok, acc} ->
      case check(line, acc) do
        {:ok, acc} -> {:cont, {:ok, %{acc | previous: digest(line <> "\n")}}}
        :error -> {:halt, {:error, {:effect_journal_corrupt, n}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, acc}
      error -> error
    end
  end

  defp check(line, acc) do
    with {:ok, %{} = r} <- Jason.decode(line),
         true <- r["schema"] == @schema and r["v"] === 1 and r["prev_line_sha256"] == acc.previous,
         {:ok, fields} <- Map.fetch(@fields, r["kind"]),
         true <- Enum.sort(Map.keys(r)) == Enum.sort(@common ++ fields),
         true <- valid_values?(r),
         {:ok, acc} <- apply_record(r["kind"], r, acc) do
      {:ok, acc}
    else
      _ -> :error
    end
  end

  defp valid_values?(%{"kind" => "end"} = r),
    do:
      marker?(r["marker_id"]) and code?(r["code"]) and (is_nil(r["cleanup"]) or code?(r["cleanup"]))

  defp valid_values?(r) do
    marker?(r["marker_id"]) and ReceiptLog.valid_pane?(r["pane_id"]) and
      ReceiptLog.valid_id?(r["msg_id"]) and is_integer(r["attempt"]) and r["attempt"] >= 1 and
      is_binary(r["buffer"]) and Regex.match?(~r/\Aai_pair_[0-9]+\z/, r["buffer"])
  end

  # retained lines form a strictly ascending prefix; a begin's marker is new; a residual
  # equals its earlier begin; an end follows its begin once, after its residual if cleanup
  # failed; no marker or buffer appears in two retained/residual records; at most 256.
  defp apply_record("retained", r, %{live: false} = acc) do
    last = acc.residuals |> Map.keys() |> Enum.max(fn -> "" end)

    if r["marker_id"] > last and not buffer_taken?(acc, r["buffer"]),
      do: add_residual(acc, r),
      else: :error
  end

  defp apply_record("retained", _r, _acc), do: :error

  defp apply_record("begin", r, acc) do
    marker = r["marker_id"]

    if Map.has_key?(acc.open, marker) or MapSet.member?(acc.ends, marker) or
         Map.has_key?(acc.residuals, marker),
       do: :error,
       else:
         {:ok, %{acc | live: true, open: Map.put(acc.open, marker, r), order: [marker | acc.order]}}
  end

  defp apply_record("residual", r, acc) do
    case Map.fetch(acc.open, r["marker_id"]) do
      {:ok, begin} ->
        same = Map.take(begin, @fields["residual"]) == Map.take(r, @fields["residual"])

        if same and not Map.has_key?(acc.residuals, r["marker_id"]) and
             not buffer_taken?(acc, r["buffer"]),
           do: add_residual(%{acc | live: true}, r),
           else: :error

      :error ->
        :error
    end
  end

  defp apply_record("end", r, acc) do
    marker = r["marker_id"]
    needs_residual = r["cleanup"] not in [nil, 0]

    cond do
      not Map.has_key?(acc.open, marker) ->
        :error

      # a residual is recorded exactly when the cleanup failed
      needs_residual != Map.has_key?(acc.residuals, marker) ->
        :error

      true ->
        {:ok,
         %{acc | live: true, open: Map.delete(acc.open, marker), ends: MapSet.put(acc.ends, marker)}}
    end
  end

  defp add_residual(acc, r) do
    residuals = Map.put(acc.residuals, r["marker_id"], Map.put(r, "kind", "residual"))
    if map_size(residuals) > @max_residuals, do: :error, else: {:ok, %{acc | residuals: residuals}}
  end

  defp buffer_taken?(acc, buffer),
    do: Enum.any?(Map.values(acc.residuals), &(&1["buffer"] == buffer))

  defp marker?(m), do: is_binary(m) and Regex.match?(~r/\Amk_[0-9a-f]{32}\z/, m)
  defp code?(c), do: is_integer(c) and c >= 0 and c <= 255

  defp repair(_fs, _path, _size, 0), do: :ok

  defp repair(fs, path, size, torn),
    do: named(Fs.truncate(fs, path, size - torn), :effect_truncate_failed)

  # ===== durable writes =====

  # Canonical form: retained lines sorted by marker_id, then uncleared begins in their order,
  # re-chained from the anchor; written to a temp file, fsynced, renamed over the journal and
  # the directory fsynced. Compacting a compacted journal yields the same bytes.
  #
  # Recovery bound: before the rename, the old file is untouched. After it, a crash before the
  # directory fsync may leave either the old file or the new one under the name; both are
  # valid journals with the same uncleared markers and residuals (the new one is the old
  # one's canonical form). Any failure is returned, never ignored: at open it refuses the
  # store start; during an epoch the store treats it as a journal write failure and poisons
  # the gate.
  defp compact(%__MODULE__{} = j) do
    retained =
      j.residuals
      |> Map.values()
      |> Enum.sort_by(& &1["marker_id"])
      |> Enum.map(&(&1 |> Map.take(@fields["retained"]) |> Map.put("kind", "retained")))

    order = Enum.filter(j.order, &Map.has_key?(j.open, &1))
    begins = Enum.map(order, &Map.take(j.open[&1], ["kind" | @fields["begin"]]))
    {lines, previous} = chain(retained ++ begins, @anchor)
    bytes = IO.iodata_to_binary(lines)
    dir = Path.dirname(j.path)
    temp = j.path <> ".compact"

    with :ok <- close(j),
         :ok <- named(Fs.mkdir_p(j.fs, dir, 0o700), :effect_dir_failed),
         :ok <- write_file(j.fs, temp, bytes),
         :ok <- named(Fs.rename(j.fs, temp, j.path), :effect_rename_failed),
         :ok <- named(Fs.dir_sync(j.fs, j.path), :effect_dir_sync_failed),
         {:ok, fd} <- named(Fs.open(j.fs, j.path), :effect_open_failed),
         :ok <- named(Fs.chmod(j.fs, j.path, 0o600), :effect_chmod_failed) do
      {:ok, %{j | fd: fd, previous: previous, size: byte_size(bytes)}}
    end
  end

  defp write_file(fs, path, bytes) do
    _ = Fs.unlink(fs, path)

    case named(Fs.open_exclusive(fs, path), :effect_temp_failed) do
      {:ok, fd} ->
        written =
          with :ok <- named(Fs.chmod(fs, path, 0o600), :effect_chmod_failed),
               :ok <- named(Fs.write(fs, fd, bytes), :effect_write_failed),
               do: named(Fs.sync(fs, fd), :effect_sync_failed)

        closed = named(Fs.close(fs, fd), :effect_close_failed)

        # The temp is closed on every path and unlinked unless complete. If that unlink also
        # fails, the leftover temp is reported in the error, never ignored; the next
        # compaction removes it before recreating it.
        case {written, closed} do
          {:ok, :ok} -> :ok
          {:ok, error} -> discard_temp(fs, path, error)
          {error, _} -> discard_temp(fs, path, error)
        end

      error ->
        error
    end
  end

  defp discard_temp(fs, path, error) do
    case Fs.unlink(fs, path) do
      :ok -> error
      {:error, :enoent} -> error
      {:error, reason} -> {:error, {:effect_temp_cleanup_failed, reason, error}}
    end
  end

  defp append(%__MODULE__{} = j, record) do
    {[line], previous} = chain([record], j.previous)

    with :ok <- named(Fs.write(j.fs, j.fd, line), :effect_write_failed),
         :ok <- named(Fs.sync(j.fs, j.fd), :effect_sync_failed) do
      {:ok, %{j | previous: previous, size: j.size + byte_size(line)}}
    end
  end

  defp chain(records, previous) do
    Enum.map_reduce(records, previous, fn record, prev ->
      line =
        record
        |> Map.merge(%{"schema" => @schema, "v" => 1, "prev_line_sha256" => prev})
        |> Jason.encode!()
        |> Kernel.<>("\n")

      {line, digest(line)}
    end)
  end

  defp digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp named(:ok, _), do: :ok
  defp named({:ok, _} = result, _), do: result
  defp named({:error, reason}, name) when is_atom(reason), do: {:error, {name, reason}}
  defp named(_, name), do: {:error, {name, :invalid_fs_result}}
end
