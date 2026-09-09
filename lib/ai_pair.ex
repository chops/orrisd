defmodule AiPair do
  @moduledoc """
  Top-level API for the ai-pair watcher and calibrator.

  Runtime entry points are the release scripts (`ai-pair-watch`, `ai-pair`,
  `ai-pair-calibrate`); this module exposes a small in-VM surface for tests
  and IPC handlers.
  """

  @spec version() :: String.t()
  def version, do: Application.spec(:ai_pair, :vsn) |> to_string()
end
