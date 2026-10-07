defmodule AiPair.Compat do
  @moduledoc """
  The durable-state compatibility contract (NS-32.M.002 RB-2; RB23-INTERFACE-SCOPE-r3).

  `reads/0` declares, per dimension, the versions this build's readers accept. It is the one
  source the release manifest's "reads" stamp is checked against.

  `observe/1` is a PURE offline parser of an inbox. It reads file bytes only, never opens a
  product reader (those repair or truncate: the receipt log drops an unterminated tail), and
  writes nothing. The bytes are judged by each module's own pure line rules
  (`ReceiptLog.observed_versions/1`, `Lineage.observed_versions/1`,
  `EffectJournal.observed_state/1`): chains, exact fields, legal transitions. Any doubt (a
  torn tail, a malformed or unknown record, an impossible transition, an unreadable or
  unlisted file) makes that dimension `:unknown`. Each dimension is `{:ok, versions}`,
  `:absent` or `:unknown`, and `"effects_hold"` says whether an uncleared effect begin exists.
  It is an early refusal only: the authority is the running daemon's fenced observation (RB-3).

  `compatible?/2` applies an observation to a target's declared reads. A target without a
  declaration (every pre-RB-2 build) and any `:unknown` dimension are `:unknown`, which callers
  treat as a refusal. This is a default refusal, not the rollback floor, which is Charles's decision.
  """

  alias AiPair.Delivery.{EffectJournal, Lineage, ReceiptLog}
  alias AiPair.PaneIntentStore.Record

  @dims ~w(effects lineage pane_intent payloads receipts)
  @payload_layout ~r/\A(snd_[0-9a-f]{64}\.[1-9][0-9]*\.[0-9a-f]{64}\.payload|\.tmp-[0-9a-f]{16})\z/

  @type dimension :: {:ok, [term()]} | :absent | :unknown
  @type observation :: %{String.t() => dimension() | boolean()}

  @spec reads() :: %{String.t() => term()}
  def reads do
    %{
      "receipts" => ReceiptLog.schema_versions(),
      "pane_intent" => Record.schemas() |> Map.keys() |> Enum.sort(),
      "lineage" => [Lineage.schema_version()],
      "effects" => [EffectJournal.version()],
      "effects_hold_aware" => true,
      "payloads" => [1]
    }
  end

  @spec observe(Path.t()) :: observation()
  def observe(inbox) do
    delivery = Path.join(inbox, "delivery")
    {effects, hold} = effects(Path.join(delivery, "effects.jsonl"))
    receipts = Path.join(delivery, "receipts.jsonl")
    lineage = Path.join(delivery, "lineage.jsonl")

    %{
      "receipts" => versions(receipts, &ReceiptLog.observed_versions/1),
      "lineage" => versions(lineage, &Lineage.observed_versions/1),
      "effects" => effects,
      "effects_hold" => hold,
      "pane_intent" => pane_intent(Path.join(inbox, "pane-attachments.json"), inbox),
      "payloads" => payloads(Path.join(delivery, "payloads"))
    }
  end

  @spec compatible?(observation(), map() | nil) ::
          :supported | :unknown | {:refused, String.t(), [term()], [term()], String.t()}
  def compatible?(observation, reads) do
    if declaration?(reads) and observation?(observation),
      do: decide(observation, reads),
      else: :unknown
  end

  # A declaration is exactly the reads/0 shape: every dimension a list, hold-awareness a boolean,
  # nothing else. Anything malformed or missing is not a declaration (fail closed).
  defp declaration?(%{} = reads) do
    Enum.sort(Map.keys(reads)) == Enum.sort(["effects_hold_aware" | @dims]) and
      Enum.all?(@dims, &is_list(reads[&1])) and is_boolean(reads["effects_hold_aware"])
  end

  defp declaration?(_), do: false

  # An observation names every dimension (a version list, :absent or :unknown) and the hold.
  defp observation?(%{} = obs) do
    Enum.all?(@dims, fn dim ->
      case obs[dim] do
        {:ok, versions} when is_list(versions) -> true
        state -> state in [:absent, :unknown]
      end
    end) and is_boolean(obs["effects_hold"]) and consistent_hold?(obs)
  end

  defp observation?(_), do: false

  # A hold exists only in a journal that holds at least one record: a hold with absent, unknown
  # or empty effects is an impossible observation.
  defp consistent_hold?(%{"effects_hold" => false}), do: true
  defp consistent_hold?(%{"effects" => {:ok, [_ | _]}}), do: true
  defp consistent_hold?(_), do: false

  defp decide(observation, reads) do
    Enum.reduce_while(@dims, :supported, fn dim, :supported ->
      case check(dim, observation[dim], reads[dim], observation, reads) do
        :ok -> {:cont, :supported}
        other -> {:halt, other}
      end
    end)
  end

  defp check(_dim, :absent, _accepted, _obs, _reads), do: :ok
  defp check(_dim, :unknown, _accepted, _obs, _reads), do: :unknown

  defp check("effects", {:ok, versions}, accepted, obs, reads) do
    cond do
      versions -- accepted != [] ->
        refusal("effects", versions, accepted)

      obs["effects_hold"] == true and reads["effects_hold_aware"] != true ->
        {:refused, "effects", versions, accepted,
         "an unresolved effect hold is present and the target does not read effect holds; " <>
           "resolve the hold on the current generation before switching"}

      true ->
        :ok
    end
  end

  defp check(dim, {:ok, versions}, accepted, _obs, _reads) do
    if versions -- accepted == [], do: :ok, else: refusal(dim, versions, accepted)
  end

  defp refusal(dim, observed, accepted) do
    {:refused, dim, observed, accepted,
     "the target reads #{dim} versions #{inspect(accepted)} but the state holds #{inspect(observed)}; " <>
       "keep the current generation, or choose a target that reads these versions"}
  end

  # ----- the pure offline parsers (read-only; any doubt is :unknown) -----

  defp versions(path, validator) do
    case bytes(path) do
      {:ok, bytes} ->
        case validator.(bytes) do
          {:ok, versions} -> {:ok, versions}
          :error -> :unknown
        end

      other ->
        other
    end
  end

  defp effects(path) do
    case bytes(path) do
      {:ok, bytes} ->
        case EffectJournal.observed_state(bytes) do
          {:ok, versions, hold} -> {{:ok, versions}, hold}
          :error -> {:unknown, false}
        end

      other ->
        {other, false}
    end
  end

  defp bytes(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :enoent} -> :absent
      {:error, _} -> :unknown
    end
  end

  # The whole envelope is judged by Record's own pure decoder (duplicate keys, exact envelope
  # keys, every record, project_inbox equal to the inbox root); only then is its version read.
  defp pane_intent(path, root) do
    case bytes(path) do
      {:ok, bytes} ->
        with {:ok, _records} <- Record.decode_envelope(bytes, root),
             {:ok, %{"schema_version" => v}} when is_binary(v) <- Jason.decode(bytes) do
          {:ok, [v]}
        else
          _ -> :unknown
        end

      other ->
        other
    end
  end

  defp payloads(dir) do
    case File.ls(dir) do
      {:error, :enoent} ->
        :absent

      {:ok, names} ->
        if Enum.all?(names, &Regex.match?(@payload_layout, &1)),
          do: {:ok, if(names == [], do: [], else: [1])},
          else: :unknown

      {:error, _} ->
        :unknown
    end
  end
end
