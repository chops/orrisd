defmodule AiPair.Test.MarkerClassifier do
  @moduledoc """
  Test classifier that maps embedded markers in the captured text to
  states. Lets state-machine tests drive transitions deterministically
  without depending on real fingerprints or terminal output.

      "...IDLE_MARKER..." -> :idle
      "...BUSY_MARKER..." -> :busy
      ...
  """

  @behaviour AiPair.Pane.Classifier

  @impl true
  def classify(stripped) do
    cond do
      String.contains?(stripped, "BUSY_MARKER") -> :busy
      String.contains?(stripped, "IDLE_MARKER") -> :idle
      String.contains?(stripped, "DIALOG_MARKER") -> :dialog
      true -> :unknown
    end
  end
end
