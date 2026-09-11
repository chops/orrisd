defmodule AiPair.PaneIntentStore.Record do
  @moduledoc """
  Closed-format validation for pane attachment records and their envelope.

  Two rules shape everything here.

  First, the format is CLOSED. A record has exactly thirteen string keys and an
  envelope exactly three; an unknown key, a missing key, a wrong type, an
  unsupported version or a key that disagrees with its record's `pane_id` is a
  visible error, never a default and never a repair. The whole file is validated
  before any record is returned, so a corrupt tail cannot be served as a healthy
  prefix.

  Second, nothing untrusted becomes an atom. Input keys and values are compared
  as binaries against fixed literals; there is no `String.to_atom/1`,
  `binary_to_atom` or equivalent anywhere in this module. A crafted file can
  therefore grow the atom table by exactly nothing.

  Records describe a desired attachment plus hints supplied by callers. Storage
  never certifies identity, liveness, permission or model, and the `agent`,
  `classifier` and `command` strings are opaque - this module never executes
  them.
  """

  @version "1.0"

  @record_keys ~w(
    schema_version pane_id agent classifier project project_dir project_inbox
    tmux_session session_gen cwd command pane_pid updated_at
  )

  @envelope_keys ~w(schema_version updated_at attachments)

  # Absolute, normalised paths. `project_inbox` is additionally pinned to the root.
  @path_keys ~w(project_dir project_inbox cwd)

  # Opaque, non-empty, NUL-free UTF-8.
  @text_keys ~w(agent classifier project tmux_session command)

  @pane_id_format ~r/\A%[0-9]+\z/
  @generation_format ~r/\A[0-9]+\z/

  @doc "The exact thirteen record keys, in contract order."
  @spec record_keys() :: [String.t()]
  def record_keys, do: @record_keys

  @doc "The supported schema version. There is no compatibility range."
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Validate one record supplied by a caller.

  `root` is the configured canonical root; `project_inbox` must equal it exactly,
  so a record's own path fields can never redirect where the store writes.
  """
  @spec validate(term(), Path.t()) :: :ok | {:error, term()}
  def validate(record, root) when is_map(record) do
    with :ok <- exact_keys(record, @record_keys, :record),
         :ok <- literal(record, "schema_version", @version),
         :ok <- pane_id(record),
         :ok <- pane_pid(record),
         :ok <- session_gen(record),
         :ok <- texts(record),
         :ok <- paths(record, root),
         :ok <- timestamp(record, "updated_at") do
      :ok
    end
  end

  def validate(_record, _root), do: {:error, {:record, :not_a_map}}

  @doc """
  Decode and validate a whole persisted envelope.

  Returns records in lexicographic binary `pane_id` order. Decoding problems -
  malformed JSON and duplicate object keys - report `:decode`; structural and
  value problems report `:schema`.
  """
  @spec decode_envelope(binary(), Path.t()) ::
          {:ok, [map()]} | {:error, {:decode | :schema, term()}}
  def decode_envelope(bytes, root) when is_binary(bytes) do
    case Jason.decode(bytes, objects: :ordered_objects) do
      {:ok, ordered} ->
        with {:ok, plain} <- reject_duplicate_keys(ordered),
             {:ok, records} <- validate_envelope(plain, root) do
          {:ok, records}
        end

      {:error, reason} ->
        {:error, {:decode, {:json, reason}}}
    end
  end

  @doc "Render a validated snapshot as canonical envelope bytes."
  @spec encode_envelope([map()], DateTime.t()) :: binary()
  def encode_envelope(records, now) do
    attachments = Map.new(records, fn record -> {record["pane_id"], record} end)

    Jason.encode!(%{
      "schema_version" => @version,
      "updated_at" => DateTime.to_iso8601(now),
      "attachments" => attachments
    })
  end

  @doc "Sort records by binary `pane_id`. Decimal numeric order is not promised."
  @spec sort([map()]) :: [map()]
  def sort(records), do: Enum.sort_by(records, & &1["pane_id"])

  # ------------------------------------------------------------------ envelope

  defp validate_envelope(envelope, root) when is_map(envelope) do
    with :ok <- exact_keys(envelope, @envelope_keys, :envelope),
         :ok <- literal(envelope, "schema_version", @version),
         :ok <- timestamp(envelope, "updated_at"),
         attachments when is_map(attachments) <- envelope["attachments"],
         :ok <- validate_attachments(attachments, root) do
      {:ok, attachments |> Map.values() |> sort()}
    else
      {:error, reason} -> {:error, {:schema, reason}}
      _not_a_map -> {:error, {:schema, {:attachments, :not_an_object}}}
    end
  end

  defp validate_envelope(_envelope, _root), do: {:error, {:schema, :not_an_object}}

  defp validate_attachments(attachments, root) do
    Enum.reduce_while(attachments, :ok, fn {key, record}, :ok ->
      cond do
        not is_binary(key) ->
          {:halt, {:error, {:attachments, :non_string_key}}}

        not is_map(record) ->
          {:halt, {:error, {:attachments, key, :not_an_object}}}

        record["pane_id"] != key ->
          {:halt, {:error, {:attachments, key, :key_disagrees_with_pane_id}}}

        true ->
          case validate(record, root) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:attachments, key, reason}}}
          end
      end
    end)
  end

  # A duplicate object key is a decode-level defect: the bytes do not denote one
  # unambiguous document. Jason's default decoder silently keeps the last
  # occurrence, so ordered objects are decoded and the duplicates rejected here
  # rather than resolved by a rule the format never states.
  defp reject_duplicate_keys(%Jason.OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, fn {k, _v} -> k end)

    if length(Enum.uniq(keys)) == length(keys) do
      pairs
      |> Enum.reduce_while({:ok, %{}}, fn {k, v}, {:ok, acc} ->
        case reject_duplicate_keys(v) do
          {:ok, plain} -> {:cont, {:ok, Map.put(acc, k, plain)}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    else
      {:error, {:decode, {:duplicate_key, keys -- Enum.uniq(keys)}}}
    end
  end

  defp reject_duplicate_keys(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case reject_duplicate_keys(value) do
        {:ok, plain} -> {:cont, {:ok, [plain | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _} = error -> error
    end
  end

  defp reject_duplicate_keys(scalar), do: {:ok, scalar}

  # -------------------------------------------------------------------- fields

  defp exact_keys(map, expected, what) do
    actual = Map.keys(map)

    cond do
      not Enum.all?(actual, &is_binary/1) -> {:error, {what, :non_string_keys}}
      MapSet.new(actual) == MapSet.new(expected) -> :ok
      true -> {:error, {what, {:keys, actual -- expected, expected -- actual}}}
    end
  end

  defp literal(map, key, expected) do
    case Map.fetch(map, key) do
      {:ok, ^expected} -> :ok
      {:ok, other} -> {:error, {key, {:unsupported, other}}}
      :error -> {:error, {key, :missing}}
    end
  end

  defp pane_id(record) do
    value = record["pane_id"]

    if is_binary(value) and Regex.match?(@pane_id_format, value) do
      :ok
    else
      {:error, {"pane_id", :malformed}}
    end
  end

  defp pane_pid(record) do
    case record["pane_pid"] do
      value when is_integer(value) and value > 0 -> :ok
      other -> {:error, {"pane_pid", {:not_a_positive_integer, other}}}
    end
  end

  defp session_gen(record) do
    value = record["session_gen"]

    if is_binary(value) and Regex.match?(@generation_format, value) do
      :ok
    else
      {:error, {"session_gen", :malformed}}
    end
  end

  defp texts(record) do
    Enum.reduce_while(@text_keys, :ok, fn key, :ok ->
      case safe_text(record[key]) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {key, reason}}}
      end
    end)
  end

  defp safe_text(value) do
    cond do
      not is_binary(value) -> {:error, :not_a_string}
      value == "" -> {:error, :empty}
      not String.valid?(value) -> {:error, :not_utf8}
      String.contains?(value, <<0>>) -> {:error, :contains_nul}
      true -> :ok
    end
  end

  defp paths(record, root) do
    with :ok <- absolute_paths(record) do
      if record["project_inbox"] == root do
        :ok
      else
        {:error, {"project_inbox", :does_not_equal_root}}
      end
    end
  end

  defp absolute_paths(record) do
    Enum.reduce_while(@path_keys, :ok, fn key, :ok ->
      value = record[key]

      cond do
        match?({:error, _}, safe_text(value)) ->
          {:halt, {:error, {key, :malformed}}}

        not String.starts_with?(value, "/") ->
          {:halt, {:error, {key, :not_absolute}}}

        Path.expand(value) != value ->
          {:halt, {:error, {key, :not_normalized}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp timestamp(map, key) do
    with value when is_binary(value) <- Map.get(map, key),
         {:ok, _datetime, 0} <- DateTime.from_iso8601(value) do
      :ok
    else
      {:ok, _datetime, _offset} -> {:error, {key, :not_utc}}
      _other -> {:error, {key, :not_iso8601}}
    end
  end
end
