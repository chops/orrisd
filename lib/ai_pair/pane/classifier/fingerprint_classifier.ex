defmodule AiPair.Pane.Classifier.Fingerprint do
  @moduledoc """
  Fingerprint-backed classifier for `AiPair.Pane.StateMachine`.

  Builds a `(binary -> state)` function bound to a loaded fingerprint
  map. Pass the result to `StateMachine`'s `:classifier` opt.

      fp = AiPair.Fingerprint.load!(path)
      classifier = AiPair.Pane.Classifier.Fingerprint.build(fp)
      AiPair.Pane.StateMachine.start_link(pane_id: ..., classifier: classifier)

  Returns `:unknown` for captures that do not match any fingerprinted
  state.
  """

  @spec build(map()) :: (binary() -> AiPair.Pane.Classifier.pane_state())
  def build(fingerprint) when is_map(fingerprint) do
    fn stripped ->
      case AiPair.Fingerprint.match(stripped, fingerprint) do
        {:ok, state} -> state
        {:error, :no_match} -> :unknown
      end
    end
  end
end
