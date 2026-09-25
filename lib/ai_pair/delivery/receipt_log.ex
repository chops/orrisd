defmodule AiPair.Delivery.ReceiptLog do
  @moduledoc false

  alias AiPair.Delivery.Fs

  @anchor "sha256:" <> Base.encode16(:crypto.hash(:sha256, ""), case: :lower)
  @schema "ai-pair/delivery-receipt"
  @schema_version 1
  @statuses ~w(pending queued delivered not_delivered ambiguous)
  @fields ~w(schema schema_version seq prev_line_sha256 daemon_epoch message_id pane_id payload_hash status delivery_attempt)
  defstruct [:fs, :fd, :path, seq: 0, previous: @anchor, entries: %{}]

  def open(fs, inbox) do
    dir = Path.join(inbox, "delivery")
    path = Path.join(dir, "receipts.jsonl")

    with :ok <- named(Fs.mkdir_p(fs, dir, 0o700), :receipt_dir_create_failed),
         {:ok, contents} <- read(fs, path),
         {:ok, log, tail_bytes} <- decode(contents, %__MODULE__{fs: fs, path: path}),
         :ok <- repair(fs, path, byte_size(contents), tail_bytes),
         {:ok, fd} <- named(Fs.open(fs, path), :receipt_open_failed) do
      log = %{log | fd: fd}

      result =
        with :ok <- named(Fs.chmod(fs, path, 0o600), :receipt_chmod_failed),
             :ok <- named(Fs.dir_sync(fs, dir), :receipt_dir_sync_failed),
             :ok <- named(Fs.dir_sync(fs, path), :receipt_dir_sync_failed),
             do: {:ok, log}

      case result do
        {:ok, _} -> result
        {:error, reason} -> close_rejected(log, reason)
      end
    end
  end

  def append(log, view, epoch) do
    record = %{
      "schema" => "ai-pair/delivery-receipt",
      "schema_version" => 1,
      "seq" => log.seq + 1,
      "prev_line_sha256" => log.previous,
      "daemon_epoch" => epoch,
      "message_id" => view.message_id,
      "pane_id" => view.pane_id,
      "payload_hash" => view.payload_hash,
      "status" => view.status,
      "delivery_attempt" => view.delivery_attempt
    }

    line = Jason.encode!(record) <> "\n"

    with :ok <- named(Fs.write(log.fs, log.fd, line), :receipt_write_failed),
         :ok <- named(Fs.sync(log.fs, log.fd), :receipt_sync_failed) do
      {:ok, accept(log, record, line)}
    end
  end

  def close(log), do: named(Fs.close(log.fs, log.fd), :receipt_close_failed)

  def valid_id?(value), do: matches?(value, ~r/\Asnd_[0-9a-f]{64}\z/)
  def valid_hash?(value), do: matches?(value, ~r/\Asha256:[0-9a-f]{64}\z/)
  def valid_pane?(value), do: matches?(value, ~r/\A%[a-zA-Z0-9_]{1,128}\z/)

  def transition?("pending", next), do: next in ~w(queued delivered not_delivered ambiguous)
  def transition?("queued", next), do: next in ~w(delivered not_delivered ambiguous)
  def transition?(_, _), do: false

  def view(record) do
    %{
      message_id: record["message_id"],
      pane_id: record["pane_id"],
      payload_hash: record["payload_hash"],
      status: record["status"],
      delivery_attempt: record["delivery_attempt"]
    }
  end

  defp read(fs, path) do
    case Fs.read(fs, path) do
      {:ok, bytes} when is_binary(bytes) -> {:ok, bytes}
      {:error, :enoent} -> {:ok, ""}
      {:ok, _invalid} -> {:error, {:receipt_read_failed, :invalid_fs_result}}
      other -> named(other, :receipt_read_failed)
    end
  end

  defp decode(bytes, log) do
    parts = :binary.split(bytes, "\n", [:global])
    {lines, [tail]} = Enum.split(parts, -1)

    Enum.reduce_while(lines, {:ok, log}, fn line, {:ok, acc} ->
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

  # A version mismatch is reported as such before the record rules run, so a line from
  # another schema or version is never attributed to chain, key-set or history damage.
  defp decode_line(line, acc) do
    seq = acc.seq + 1

    case Jason.decode(line) do
      {:ok, %{} = record} -> check_line(record, classify_version(record), acc, seq)
      _ -> corrupt(seq)
    end
  end

  defp check_line(_record, {:incompatible, found}, _acc, seq), do: incompatible(seq, found)

  defp check_line(record, _own_or_other, acc, seq) do
    if valid_record?(record, acc), do: {:ok, record}, else: corrupt(seq)
  end

  # The unterminated final bytes, classified after the complete prefix has validated.
  # Only a fragment that does not decode, or an own-version object that passes full
  # validation against that prefix, is a repairable torn write. Every other complete
  # value is refused here, before repair/4, so a refusal never truncates the file.
  defp classify_tail("", decoded), do: {:ok, decoded, 0}

  defp classify_tail(tail, decoded) do
    seq = decoded.seq + 1

    case Jason.decode(tail) do
      {:error, _fragment} -> {:ok, decoded, byte_size(tail)}
      {:ok, %{} = record} -> classify_tail_record(record, decoded, byte_size(tail), seq)
      {:ok, _not_an_object} -> corrupt(seq)
    end
  end

  defp classify_tail_record(record, decoded, tail_bytes, seq) do
    case classify_version(record) do
      {:incompatible, found} -> incompatible(seq, found)
      :other -> corrupt(seq)
      :ok -> repairable(valid_record?(record, decoded), decoded, tail_bytes, seq)
    end
  end

  defp repairable(true, decoded, tail_bytes, _seq), do: {:ok, decoded, tail_bytes}
  defp repairable(false, _decoded, _tail_bytes, seq), do: corrupt(seq)

  # :ok for the pair this build reads, {:incompatible, found} for a map carrying both
  # keys with any other pair (type-confused versions included), :other otherwise.
  defp classify_version(%{"schema" => @schema, "schema_version" => @schema_version}), do: :ok

  defp classify_version(%{"schema" => schema, "schema_version" => version}),
    do: {:incompatible, %{schema: found_schema(schema), schema_version: found_version(version)}}

  defp classify_version(_record), do: :other

  # Found values are echoed only when bounded; anything else becomes a fixed marker, so
  # no raw long or control-character content reaches the reason or its inspect output.
  defp found_schema(schema) do
    if matches?(schema, ~r/\A[a-z0-9][a-z0-9\/._-]{0,63}\z/), do: schema, else: :unrecognized
  end

  defp found_version(v) when is_integer(v) and v in 0..1_000_000, do: v
  defp found_version(v) when is_integer(v), do: {:unsupported_type, :integer_out_of_range}
  defp found_version(v) when is_binary(v), do: {:unsupported_type, :string}
  defp found_version(v) when is_float(v), do: {:unsupported_type, :float}
  defp found_version(nil), do: {:unsupported_type, :null}
  defp found_version(v) when is_boolean(v), do: {:unsupported_type, :boolean}
  defp found_version(v) when is_list(v), do: {:unsupported_type, :array}
  defp found_version(v) when is_map(v), do: {:unsupported_type, :object}

  defp incompatible(seq, found) do
    expected = %{schema: @schema, schema_version: @schema_version}
    {:error, {:receipt_log_incompatible, %{seq: seq, found: found, expected: expected}}}
  end

  defp corrupt(seq), do: {:error, {:receipt_log_corrupt, seq}}

  defp valid_record?(r, log) do
    Enum.sort(Map.keys(r)) == Enum.sort(@fields) and
      r["schema"] == "ai-pair/delivery-receipt" and r["schema_version"] === 1 and
      r["seq"] === log.seq + 1 and r["prev_line_sha256"] == log.previous and
      matches?(r["daemon_epoch"], ~r/\Aep_[0-9a-f]{24}\z/) and
      valid_id?(r["message_id"]) and valid_hash?(r["payload_hash"]) and
      valid_pane?(r["pane_id"]) and r["status"] in @statuses and
      is_integer(r["delivery_attempt"]) and history_valid?(log.entries[r["message_id"]], r)
  end

  defp history_valid?(nil, r), do: r["status"] == "pending" and r["delivery_attempt"] == 1

  defp history_valid?(old, r) do
    same_identity = old["pane_id"] == r["pane_id"] and old["payload_hash"] == r["payload_hash"]

    same_identity and
      ((r["delivery_attempt"] == old["delivery_attempt"] and transition?(old["status"], r["status"])) or
         (old["status"] == "not_delivered" and r["status"] == "pending" and
            r["delivery_attempt"] == old["delivery_attempt"] + 1))
  end

  defp repair(_fs, _path, _size, 0), do: :ok

  defp repair(fs, path, size, tail),
    do: named(Fs.truncate(fs, path, size - tail), :receipt_truncate_failed)

  defp accept(log, record, line) do
    %{
      log
      | seq: record["seq"],
        previous: digest(line),
        entries: Map.put(log.entries, record["message_id"], record)
    }
  end

  defp close_rejected(log, reason) do
    case close(log) do
      :ok -> {:error, reason}
      {:error, close_reason} -> {:error, {:receipt_open_cleanup_failed, reason, close_reason}}
    end
  end

  defp matches?(value, regex) when is_binary(value),
    do: String.valid?(value) and Regex.match?(regex, value)

  defp matches?(_, _), do: false
  defp digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp named(:ok, _), do: :ok
  defp named({:ok, _} = result, _), do: result
  defp named({:error, reason}, name) when is_atom(reason), do: {:error, {name, reason}}
  defp named(_, name), do: {:error, {name, :invalid_fs_result}}
end
