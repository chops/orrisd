defmodule AiPair.Pane.Classifier.Stub do
  @moduledoc """
  Default classifier — always returns `:unknown`.

  Used until `AiPair.Fingerprint`-backed classification is wired up.
  Tests inject their own classifier via `:classifier` opt.
  """

  @behaviour AiPair.Pane.Classifier

  @impl true
  def classify(_stripped), do: :unknown
end
