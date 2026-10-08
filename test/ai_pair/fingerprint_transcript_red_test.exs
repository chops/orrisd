defmodule AiPair.FingerprintTranscriptRedTest do
  @moduledoc """
  RED rows for the codex_cli dialog false positive (finding of 2026-10-07; design
  D/rb/CODEX-DIALOG-FINGERPRINT-DESIGN-r3.org, DESIGN GO m_20261008T011239Z) and the
  extended rows of design r6 (D/rb/CODEX-DIALOG-FINGERPRINT-DESIGN-r6.org, DESIGN GO
  m_20261008T194645Z).

  An idle Codex screen whose transcript text, within the dialog state's bottom lines, contains a
  word a dialog pattern keys on (bypass, yolo, Allow/Deny, Run command, approve <word>, a "⚠ apply"
  line, --dangerously-allow, the trust question, "Press enter to continue") must classify :idle
  when the screen ends with the real idle composer tail (prompt line, model/status line, footer).
  At the base each classifies :dialog. idle_bypass.txt is the exact measured read-only capture of
  2026-10-07 19:09Z (codex-cli 0.160.1); the others change only that one transcript line.
  idle_0161.txt is the exact read-only capture of an idle codex-cli 0.161.0 session (2026-10-08,
  footer "← for agents · ? for shortcuts"); idle_0161_bypass.txt and idle_0161_quotes_overlay.txt
  insert transcript lines above its prompt.

  The real approval overlay (dialog_overlay_proceed.txt and its resumed recapture, both exact
  read-only captures of the 2026-10-08 step-0 witness) must classify :dialog; at the base both
  classify :idle. A numbered option row in the prompt position is :dialog for both the continue
  and the proceed form.

  Controls, :dialog before and after the fix: the footer text quoted inside the transcript beside a
  dialog word with no composer tail at the bottom (old and new footer), and footers carrying an
  extra prefix or suffix. The four existing dialog fixtures stay covered by AiPair.FingerprintTest's
  sweep.
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

  for name <- ~w(idle_0161.txt idle_0161_bypass.txt idle_0161_quotes_overlay.txt) do
    @name name
    test "an idle codex-cli 0.161.0 screen stays :idle (#{name})", %{fp: fp} do
      assert classify(@name, fp) == {:ok, :idle}
    end
  end

  for name <- ~w(dialog_overlay_proceed.txt dialog_overlay_proceed_resumed.txt) do
    @name name
    test "the real approval overlay is :dialog (#{name})", %{fp: fp} do
      assert classify(@name, fp) == {:ok, :dialog}
    end
  end

  test "control: a numbered option row in the prompt position is still :dialog", %{fp: fp} do
    assert classify("dialog_option_row_tail.txt", fp) == {:ok, :dialog}
  end

  test "control: the footer quoted in transcript text without the composer tail is still :dialog",
       %{fp: fp} do
    assert classify("dialog_quoted_footer.txt", fp) == {:ok, :dialog}
  end

  test "the proceed option row in the prompt position is :dialog", %{fp: fp} do
    assert classify("dialog_option_row_tail_proceed.txt", fp) == {:ok, :dialog}
  end

  test "control: the 0.161.0 footer quoted without the composer tail is still :dialog", %{fp: fp} do
    assert classify("dialog_quoted_footer_0161.txt", fp) == {:ok, :dialog}
  end

  for name <- ~w(dialog_footer_prefix_mutation.txt dialog_footer_suffix_mutation.txt) do
    @name name
    test "control: a footer with an extra prefix or suffix grants no tail exemption (#{name})",
         %{fp: fp} do
      assert classify(@name, fp) == {:ok, :dialog}
    end
  end

  test "the fixture set is exactly the reviewed one" do
    assert @dir |> File.ls!() |> Enum.sort() ==
             ~w(dialog_footer_prefix_mutation.txt dialog_footer_suffix_mutation.txt
                dialog_option_row_tail.txt dialog_option_row_tail_proceed.txt
                dialog_overlay_proceed.txt dialog_overlay_proceed_resumed.txt
                dialog_quoted_footer.txt dialog_quoted_footer_0161.txt idle_0161.txt
                idle_0161_bypass.txt idle_0161_quotes_overlay.txt idle_allow_deny.txt
                idle_approve.txt idle_bypass.txt idle_dangerously_allow.txt idle_press_enter.txt
                idle_run_command.txt idle_trust_question.txt idle_warn_apply.txt idle_yolo.txt)
  end
end
