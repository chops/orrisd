defmodule AiPair.Pane.Classifier.Loader do
  @moduledoc """
  Resolves an agent string to a fingerprint-backed classifier closure.

  Used by the IPC server's `attach_pane` dispatch to translate
  `{"agent": "claude_code"}` into a `(classifier_fn, classifier_name)`
  pair that can be injected into a per-pane `StateMachine`. On any
  failure (unknown agent, missing/corrupt fingerprint JSON), returns
  `{:fallback, reason}` so the caller can fall back to
  `AiPair.Pane.Classifier.Stub` with explicit observability — never
  raises.

  Lookup is lazy: each call resolves the priv path, reads the JSON,
  and builds a closure. Attach is not the hot path and fingerprints
  are tiny; reload-on-disk during calibration work is a feature, not
  a cost.
  """

  alias AiPair.Pane.Classifier.Fingerprint, as: FingerprintClassifier

  @type agent :: String.t()
  @type classifier_fn :: (binary() -> AiPair.Pane.Classifier.pane_state())
  @type fallback_reason ::
          :unknown_agent
          | :priv_dir_unavailable
          | {:load_failed, term()}

  @known_agents %{
    "claude_code" => "claude_code.json",
    "codex_cli" => "codex_cli.json"
  }

  @doc "Set of agent strings the loader knows about."
  @spec known_agents() :: [agent()]
  def known_agents, do: Map.keys(@known_agents)

  @doc """
  Resolve `agent` to a classifier closure.

  Returns `{:ok, classifier_fn, classifier_name}` on success.
  `classifier_name` is suitable for telemetry / IPC reply use and is
  shaped as `"fingerprint:<agent>"`.

  Returns `{:fallback, reason}` for: unknown agent strings,
  unavailable priv dir (only happens if `:ai_pair` isn't loaded),
  or any `AiPair.Fingerprint.load/1` failure (missing file, invalid
  JSON, decode error). The caller is expected to log and fall back
  to the Stub classifier.
  """
  @spec load_for_agent(agent()) ::
          {:ok, classifier_fn(), String.t()} | {:fallback, fallback_reason()}
  def load_for_agent(agent) when is_binary(agent) do
    case Map.fetch(@known_agents, agent) do
      :error ->
        {:fallback, :unknown_agent}

      {:ok, filename} ->
        with {:ok, dir} <- priv_fingerprints_dir(),
             path = Path.join(dir, filename),
             {:ok, fp} <- AiPair.Fingerprint.load(path) do
          {:ok, FingerprintClassifier.build(fp), "fingerprint:#{agent}"}
        else
          {:fallback, _} = fallback -> fallback
          {:error, reason} -> {:fallback, {:load_failed, reason}}
        end
    end
  end

  defp priv_fingerprints_dir do
    case Application.get_env(:ai_pair, :fingerprint_dir) do
      nil ->
        case :code.priv_dir(:ai_pair) do
          {:error, _} -> {:fallback, :priv_dir_unavailable}
          path -> {:ok, Path.join(to_string(path), "fingerprints")}
        end

      override when is_binary(override) ->
        {:ok, override}
    end
  end
end
