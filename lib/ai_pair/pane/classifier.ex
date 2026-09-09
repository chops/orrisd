defmodule AiPair.Pane.Classifier do
  @moduledoc """
  Behaviour for pane-state classifiers.

  A classifier takes the stripped (no ANSI) bottom of a captured pane and
  returns one of `:idle | :busy | :dialog | :unknown`. The
  state machine handles `:dead` separately (pane disappearance, not text).

  The fingerprint classifier uses the profiles in `priv/fingerprints/`.
  A stub that always returns `:unknown` is available as a fallback.
  """

  @type pane_state :: :idle | :busy | :dialog | :unknown

  @callback classify(stripped :: binary()) :: pane_state()
end
