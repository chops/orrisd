defmodule AiPair.Delivery.Lineage do
  @moduledoc false
  # NS-15.G.003 S2: the per-epoch writer attestation, <inbox>/delivery/lineage.jsonl.
  #
  # One hash-chained record per boot, appended and fsynced before the store accepts any call
  # or writes any receipt of that epoch. An epoch with a record is attested: its queued
  # attempts may be restored. A missing file attests nothing. A corrupt or inconsistent file
  # refuses the whole store unchanged; only a torn final line is repaired.

  alias AiPair.Delivery.Fs

  @anchor "sha256:" <> Base.encode16(:crypto.hash(:sha256, ""), case: :lower)
  @schema "ai-pair/delivery-lineage"
  @writer "payload-marker-1"
  @writers [@writer]
  @fields ~w(schema schema_version seq prev_line_sha256 daemon_epoch writer first_receipt_seq)

  defstruct [:fs, :path, records: [], seq: 0, previous: @anchor, tail_bytes: 0, size: 0]

  def writer, do: @writer

  @doc "The lineage schema version this build writes and reads (AiPair.Compat.reads/0)."
  @spec schema_version() :: pos_integer()
  def schema_version, do: 1

  @doc """
  Pure validation of lineage bytes for AiPair.Compat.observe/1, by this module's own line rules
  (chain, key set, order): the versions of a fully valid, newline-terminated file, or :error.
  No I/O; the receipt-log consistency check needs the open log and is the fenced observer's.
  """
  @spec observed_versions(binary()) :: {:ok, [pos_integer()]} | :error
  def observed_versions(bytes) when is_binary(bytes) do
    case decode(bytes, %__MODULE__{}) do
      {:ok, %__MODULE__{tail_bytes: 0, records: []}} -> {:ok, []}
      {:ok, %__MODULE__{tail_bytes: 0}} -> {:ok, [schema_version()]}
      _ -> :error
    end
  end

  @doc "Read and validate lineage against an opened receipt log; nothing is written."
  def load(fs, inbox, log) do
    path = Path.join([inbox, "delivery", "lineage.jsonl"])

    with {:ok, bytes} <- read(fs, path),
         {:ok, lineage} <- decode(bytes, %__MODULE__{fs: fs, path: path}),
         :ok <- consistent(lineage, log) do
      {:ok, %{lineage | size: byte_size(bytes)}}
    end
  end

  @doc "Repair a torn tail, then append and fsync the new epoch's record."
  def attest(%__MODULE__{} = lineage, epoch, first_receipt_seq) do
    record = %{
      "schema" => @schema,
      "schema_version" => 1,
      "seq" => lineage.seq + 1,
      "prev_line_sha256" => lineage.previous,
      "daemon_epoch" => epoch,
      "writer" => @writer,
      "first_receipt_seq" => first_receipt_seq
    }

    line = Jason.encode!(record) <> "\n"
    created = not Fs.exists?(lineage.fs, lineage.path)

    with :ok <- repair(lineage),
         {:ok, fd} <- Fs.open(lineage.fs, lineage.path) do
      result =
        with :ok <- Fs.chmod(lineage.fs, lineage.path, 0o600),
             :ok <- Fs.write(lineage.fs, fd, line),
             :ok <- Fs.sync(lineage.fs, fd),
             :ok <- if(created, do: Fs.dir_sync(lineage.fs, lineage.path), else: :ok) do
          :ok
        end

      _ = Fs.close(lineage.fs, fd)

      case result do
        :ok -> {:ok, %{lineage | records: lineage.records ++ [record], seq: record["seq"]}}
        _ -> {:error, :lineage_unavailable}
      end
    else
      _ -> {:error, :lineage_unavailable}
    end
  end

  @doc "Attested epochs and their receipt seq ranges: %{epoch => {first, last | :infinity}}."
  def ranges(%__MODULE__{records: records}) do
    firsts = Enum.map(records, & &1["first_receipt_seq"])
    nexts = Enum.drop(firsts, 1) |> Enum.map(&(&1 - 1))

    records
    |> Enum.zip(nexts ++ [:infinity])
    |> Map.new(fn {r, last} -> {r["daemon_epoch"], {r["first_receipt_seq"], last}} end)
  end

  defp read(fs, path) do
    case Fs.read(fs, path) do
      {:ok, bytes} when is_binary(bytes) -> {:ok, bytes}
      {:error, :enoent} -> {:ok, ""}
      _ -> {:error, :lineage_unavailable}
    end
  end

  defp decode(bytes, lineage) do
    parts = :binary.split(bytes, "\n", [:global])
    {lines, [tail]} = Enum.split(parts, -1)

    lines
    |> Enum.reduce_while({:ok, lineage}, fn line, {:ok, acc} ->
      case decode_line(line, acc) do
        {:ok, record} -> {:cont, {:ok, accept(acc, record, line <> "\n")}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} -> classify_tail(tail, decoded)
      error -> error
    end
  end

  defp decode_line(line, acc) do
    case Jason.decode(line) do
      {:ok, %{} = record} ->
        if valid?(record, acc), do: {:ok, record}, else: corrupt(acc.seq + 1)

      _ ->
        corrupt(acc.seq + 1)
    end
  end

  # An unterminated final fragment is a torn write and is repaired; an unterminated value that
  # decodes is repaired only when it is itself a valid next record. Anything else is corrupt.
  defp classify_tail("", decoded), do: {:ok, decoded}

  defp classify_tail(tail, decoded) do
    case Jason.decode(tail) do
      {:error, _fragment} ->
        {:ok, %{decoded | tail_bytes: byte_size(tail)}}

      {:ok, %{} = record} ->
        if valid?(record, decoded),
          do: {:ok, %{decoded | tail_bytes: byte_size(tail)}},
          else: corrupt(decoded.seq + 1)

      {:ok, _} ->
        corrupt(decoded.seq + 1)
    end
  end

  defp valid?(r, acc) do
    Enum.sort(Map.keys(r)) == Enum.sort(@fields) and r["schema"] == @schema and
      r["schema_version"] === 1 and r["seq"] === acc.seq + 1 and
      r["prev_line_sha256"] == acc.previous and epoch?(r["daemon_epoch"]) and
      r["writer"] in @writers and is_integer(r["first_receipt_seq"]) and
      r["first_receipt_seq"] >= 1 and
      not Enum.any?(acc.records, &(&1["daemon_epoch"] == r["daemon_epoch"])) and
      ordered?(List.last(acc.records), r)
  end

  # Design r5/r6: first_receipt_seq never decreases. An epoch that appends no receipt leaves the
  # next boot's value equal, which gives that epoch an empty range.
  defp ordered?(nil, _r), do: true
  defp ordered?(prev, r), do: r["first_receipt_seq"] >= prev["first_receipt_seq"]

  # Epoch ranges against the log's epoch runs (ReceiptLog keeps contiguous same-epoch runs).
  defp consistent(%__MODULE__{records: []}, _log), do: :ok

  defp consistent(lineage, log) do
    last = List.last(lineage.records)

    cond do
      last["first_receipt_seq"] > log.seq + 1 ->
        inconsistent(last["seq"])

      true ->
        ranges = ranges(lineage)

        log.runs
        |> Enum.reverse()
        |> Enum.reduce_while(%{}, fn {epoch, first, last_seq}, seen ->
          case Map.fetch(ranges, epoch) do
            :error ->
              {:cont, seen}

            {:ok, {f, g}} ->
              if Map.has_key?(seen, epoch) or first != f or (g != :infinity and last_seq > g),
                do: {:halt, {:bad, epoch}},
                else: {:cont, Map.put(seen, epoch, true)}
          end
        end)
        |> case do
          {:bad, epoch} ->
            inconsistent(Enum.find(lineage.records, &(&1["daemon_epoch"] == epoch))["seq"])

          _ ->
            :ok
        end
    end
  end

  defp repair(%__MODULE__{tail_bytes: 0}), do: :ok

  defp repair(lineage) do
    with :ok <- Fs.truncate(lineage.fs, lineage.path, lineage.size - lineage.tail_bytes),
         {:ok, fd} <- Fs.open(lineage.fs, lineage.path) do
      result = Fs.sync(lineage.fs, fd)
      _ = Fs.close(lineage.fs, fd)
      result
    end
  end

  defp accept(acc, record, line),
    do: %{
      acc
      | records: acc.records ++ [record],
        seq: record["seq"],
        previous: "sha256:" <> Base.encode16(:crypto.hash(:sha256, line), case: :lower)
    }

  defp epoch?(e), do: is_binary(e) and Regex.match?(~r/\Aep_[0-9a-f]{24}\z/, e)
  defp corrupt(seq), do: {:error, {:lineage_corrupt, seq}}
  defp inconsistent(seq), do: {:error, {:lineage_inconsistent, seq}}
end
