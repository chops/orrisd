defmodule AiPair.FingerprintTranscriptRedTest do
  @moduledoc """
  RED rows for the codex_cli dialog false positive (finding of 2026-10-07; design
  D/rb/CODEX-DIALOG-FINGERPRINT-DESIGN-r3.org, DESIGN GO m_20261008T011239Z).

  An idle Codex screen whose transcript text, within the dialog state's bottom lines, contains a
  word a dialog pattern keys on (bypass, yolo, Allow/Deny, Run command, approve <word>, a "⚠ apply"
  line, --dangerously-allow, the trust question, "Press enter to continue") must classify :idle
  when the screen ends with the real idle composer tail (prompt line, model/status line, footer).
  At the base each classifies :dialog. idle_bypass.txt is the exact measured read-only capture of
  2026-10-07 19:09Z; the others change only that one transcript line.

  Controls, :dialog before and after the fix: a numbered option row ("› 1. Yes, continue") in the
  prompt position above the real status and footer lines, and the footer text quoted inside the
  transcript beside a dialog word with no composer tail at the bottom. The four existing dialog
  fixtures stay covered by AiPair.FingerprintTest's sweep.

  LIMIT: no real capture of the current Codex approval overlay exists yet (decision 53, step 0);
  its :dialog regression fixture is added when captured, before any GREEN.
  """

  use ExUnit.Case, async: true

  @dir Path.expand("../fixtures/fingerprints/codex_cli/transcript", __DIR__)

  setup_all do
    {:ok,
     fp:
       AiPair.Fingerprint.load!(
         Path.join([:code.priv_dir(:ai_pair), "fingerprints", "codex_cli.json"])
       )}
  end

  defp classify(name, fp), do: AiPair.Fingerprint.match(File.read!(Path.join(@dir, name)), fp)

  for name <- ~w(idle_bypass.txt idle_yolo.txt idle_allow_deny.txt idle_run_command.txt
                 idle_approve.txt idle_warn_apply.txt idle_dangerously_allow.txt
                 idle_trust_question.txt idle_press_enter.txt) do
    @name name
    test "an idle screen whose transcript holds a dialog word stays :idle (#{name})", %{fp: fp} do
      assert classify(@name, fp) == {:ok, :idle}
    end
  end

  test "control: a numbered option row in the prompt position is still :dialog", %{fp: fp} do
    assert classify("dialog_option_row_tail.txt", fp) == {:ok, :dialog}
  end

  test "control: the footer quoted in transcript text without the composer tail is still :dialog",
       %{fp: fp} do
    assert classify("dialog_quoted_footer.txt", fp) == {:ok, :dialog}
  end

  test "the fixture set is exactly the reviewed one" do
    assert @dir |> File.ls!() |> Enum.sort() ==
             ~w(dialog_option_row_tail.txt dialog_quoted_footer.txt idle_allow_deny.txt
                idle_approve.txt idle_bypass.txt idle_dangerously_allow.txt idle_press_enter.txt
                idle_run_command.txt idle_trust_question.txt idle_warn_apply.txt idle_yolo.txt)
  end
end
