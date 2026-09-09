defmodule Mix.Tasks.AiPair.CaptureFingerprint do
  @shortdoc "Drive TUIs through idle/busy and capture fingerprint fixtures"

  @moduledoc """
  Thin Mix shim around `AiPair.Calibrator.main/1`. The actual capture
  pipeline lives in `AiPair.Calibrator` so it can be invoked from the
  release wrapper (`bin/ai-pair-calibrate`) without a Mix dependency.

      mix ai_pair.capture_fingerprint claude_code
      mix ai_pair.capture_fingerprint codex_cli
      mix ai_pair.capture_fingerprint --all
      mix ai_pair.capture_fingerprint --verify-only claude_code

  ## Environment overrides

    * `AI_PAIR_CAP_CLAUDE` — path/name of the Claude Code binary (default `claude`)
    * `AI_PAIR_CAP_CODEX`  — path/name of the Codex CLI binary  (default `codex`)
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("loadpaths")
    Mix.Task.run("app.config")

    case AiPair.Calibrator.main(args) do
      0 -> :ok
      1 -> Mix.raise("calibration failed")
      2 -> Mix.raise("usage error")
    end
  end
end
