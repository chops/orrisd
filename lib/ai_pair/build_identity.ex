defmodule AiPair.BuildIdentity do
  @moduledoc """
  The build identity a release records (NS-32.M.001 RB-1; vendored `docs/contracts/ipc-v3.org`,
  the `build_identity` token and object).

  A release carries `share/ai-pair/build-identity.json`, written at build time from the build's
  inputs. It is the eight-key record the version 3 ping reports. `read/1` returns that record
  exactly or refuses it. A record is accepted only when:

    * it is a JSON object with exactly the eight contract keys;
    * `name` and `version` are strings;
    * `source_revision` is 40 lowercase hex, or `null`;
    * `clean` and `rollback_eligible` are booleans;
    * `source_nar_hash` is a string beginning `sha256-`;
    * `build_id` is 64 lowercase hex;
    * `ipc_protocols` is a list of integers;
    * `rollback_eligible` is true exactly when `clean` is true and `source_revision` is 40 hex.

  Nothing is invented: a release without a record has no build identity.

  `load/1` is what the IPC server calls once when it starts. It returns the record, or `nil` for
  an absent or refused one. A refused record is logged once as a warning beginning
  "build_identity refused:"; an absent one is not logged.
  """

  require Logger

  @relative "share/ai-pair/build-identity.json"
  @keys ~w(build_id clean ipc_protocols name rollback_eligible source_nar_hash source_revision version)
  @revision ~r/\A[0-9a-f]{40}\z/
  @build_id ~r/\A[0-9a-f]{64}\z/

  @type identity :: %{String.t() => term()}
  @type refusal :: :absent | {:unreadable, File.posix()} | {:invalid, String.t()}

  @doc "The release root the server reads from: the `:release_root` env, else the running release's."
  @spec release_root() :: Path.t()
  def release_root,
    do: Application.get_env(:ai_pair, :release_root) || List.to_string(:code.root_dir())

  @spec read(Path.t()) :: {:ok, identity()} | {:error, refusal()}
  def read(root) do
    case File.read(Path.join(root, @relative)) do
      {:ok, bytes} -> decode(bytes)
      {:error, :enoent} -> {:error, :absent}
      {:error, reason} -> {:error, {:unreadable, reason}}
    end
  end

  @spec load(Path.t()) :: identity() | nil
  def load(root) do
    case read(root) do
      {:ok, record} ->
        record

      {:error, :absent} ->
        nil

      {:error, reason} ->
        Logger.warning("build_identity refused: #{inspect(reason)}")
        nil
    end
  end

  defp decode(bytes) do
    case Jason.decode(bytes) do
      {:ok, record} when is_map(record) -> validate(record)
      {:ok, _other} -> {:error, {:invalid, "not a JSON object"}}
      {:error, _} -> {:error, {:invalid, "not JSON"}}
    end
  end

  defp validate(record) do
    keys = record |> Map.keys() |> Enum.sort()

    cond do
      keys != @keys ->
        {:error, {:invalid, key_mismatch(keys)}}

      not (is_binary(record["name"]) and is_binary(record["version"])) ->
        {:error, {:invalid, "name and version must be strings"}}

      not revision?(record["source_revision"]) ->
        {:error, {:invalid, "source_revision must be 40 lowercase hex or null"}}

      not (is_boolean(record["clean"]) and is_boolean(record["rollback_eligible"])) ->
        {:error, {:invalid, "clean and rollback_eligible must be booleans"}}

      not (is_binary(record["source_nar_hash"]) and
               String.starts_with?(record["source_nar_hash"], "sha256-")) ->
        {:error, {:invalid, "source_nar_hash must be a string beginning sha256-"}}

      not (is_binary(record["build_id"]) and Regex.match?(@build_id, record["build_id"])) ->
        {:error, {:invalid, "build_id must be 64 lowercase hex"}}

      not (is_list(record["ipc_protocols"]) and Enum.all?(record["ipc_protocols"], &is_integer/1)) ->
        {:error, {:invalid, "ipc_protocols must be a list of integers"}}

      record["rollback_eligible"] != (record["clean"] and is_binary(record["source_revision"])) ->
        {:error, {:invalid, "rollback_eligible must equal clean with a source revision"}}

      true ->
        {:ok, record}
    end
  end

  defp revision?(nil), do: true
  defp revision?(value) when is_binary(value), do: Regex.match?(@revision, value)
  defp revision?(_), do: false

  defp key_mismatch(keys) do
    extra = keys -- @keys
    missing = @keys -- keys
    "unexpected keys: #{Enum.join(extra, ",")}; missing keys: #{Enum.join(missing, ",")}"
  end
end
