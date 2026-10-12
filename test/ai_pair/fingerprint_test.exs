defmodule AiPair.FingerprintTest do
  use ExUnit.Case, async: true

  alias AiPair.Fingerprint

  defp priv_path(name), do: Path.join([:code.priv_dir(:ai_pair), "fingerprints", name])
  defp fixture_path(parts), do: Path.join([__DIR__, "../fixtures/fingerprints"] ++ parts)

  describe "claude_code.json" do
    setup do: {:ok, fp: Fingerprint.load!(priv_path("claude_code.json"))}

    # Excluded from the busy wildcard:
    #   busy_002 — composer-busy (user typing in composer); no model spinner is
    #              visible, so screen-fingerprint cannot distinguish it from idle.
    #   busy_006 — xhigh thinking-mode emits a section heading (⏺ Topic) with no
    #              streaming spinner UI; fundamentally unfingerprintable from
    #              screen alone, requires SM temporal context.
    #   busy_009 — xhigh thinking-mode mid-stream (`⏺ :gen_statem vs :gen_server`
    #              heading rendered above an empty composer); no spinner glyph
    #              on screen. Same unfingerprintable class as busy_006.
    #   busy_010 — same pattern as 009, further into the stream (heading + first
    #              paragraph rendered, still no spinner).
    #   busy_011 — same pattern as 009/010 deeper still; the displayed bottom-of-
    #              screen is byte-shape near-identical to idle_003 with body
    #              text scrolled up. Screen alone cannot disambiguate.
    @claude_busy_skip ~w(busy_002.txt busy_006.txt busy_009.txt busy_010.txt busy_011.txt)

    test "all busy fixtures match :busy (except documented exclusions)", %{fp: fp} do
      busy_files =
        fixture_path(["claude_code", "busy_*.txt"])
        |> Path.wildcard()
        |> Enum.reject(&(Path.basename(&1) in @claude_busy_skip))
        |> Enum.sort()

      assert busy_files != [], "no busy fixtures found"

      for path <- busy_files do
        text = File.read!(path)

        assert {:ok, :busy} = Fingerprint.match(text, fp),
               "#{Path.basename(path)} should match :busy"
      end
    end

    test "all dialog fixtures match :dialog", %{fp: fp} do
      dialog_files =
        fixture_path(["claude_code", "dialog_*.txt"])
        |> Path.wildcard()
        |> Enum.sort()

      assert dialog_files != [], "no dialog fixtures found"

      for path <- dialog_files do
        text = File.read!(path)

        assert {:ok, :dialog} = Fingerprint.match(text, fp),
               "#{Path.basename(path)} should match :dialog"
      end
    end

    test "all idle fixtures match :idle", %{fp: fp} do
      idle_files =
        fixture_path(["claude_code", "idle_*.txt"])
        |> Path.wildcard()
        |> Enum.sort()

      assert idle_files != [], "no idle fixtures found"

      for path <- idle_files do
        text = File.read!(path)

        assert {:ok, :idle} = Fingerprint.match(text, fp),
               "#{Path.basename(path)} should match :idle"
      end
    end

    test "garbage text returns no_match", %{fp: fp} do
      assert {:error, :no_match} = Fingerprint.match("nothing useful here\n", fp)
    end
  end

  describe "codex_cli.json" do
    setup do: {:ok, fp: Fingerprint.load!(priv_path("codex_cli.json"))}

    test "all busy fixtures match :busy", %{fp: fp} do
      busy_files =
        fixture_path(["codex_cli", "busy_*.txt"])
        |> Path.wildcard()
        |> Enum.sort()

      assert busy_files != [], "no busy fixtures found"

      for path <- busy_files do
        text = File.read!(path)

        assert {:ok, :busy} = Fingerprint.match(text, fp),
               "#{Path.basename(path)} should match :busy"
      end
    end

    test "all dialog fixtures match :dialog", %{fp: fp} do
      dialog_files =
        fixture_path(["codex_cli", "dialog_*.txt"])
        |> Path.wildcard()
        |> Enum.sort()

      assert dialog_files != [], "no dialog fixtures found"

      for path <- dialog_files do
        text = File.read!(path)

        assert {:ok, :dialog} = Fingerprint.match(text, fp),
               "#{Path.basename(path)} should match :dialog"
      end
    end

    test "all idle fixtures match :idle", %{fp: fp} do
      idle_files =
        fixture_path(["codex_cli", "idle_*.txt"])
        |> Path.wildcard()
        |> Enum.sort()

      assert idle_files != [], "no idle fixtures found"

      for path <- idle_files do
        text = File.read!(path)

        assert {:ok, :idle} = Fingerprint.match(text, fp),
               "#{Path.basename(path)} should match :idle"
      end
    end

    # Regression: Codex 0.135's compact startup layout keeps the static
    # `│ permissions: YOLO mode │` banner inside the dialog window's
    # bottom_lines, so the dialog `\byolo\b` branch false-matched it and
    # masked the idle composer prompt underneath. The branch now excludes
    # any line containing the word "permissions"; the real YOLO approval
    # overlay is still caught via its Allow/Deny + "Trust this session" lines.
    test "static `permissions: YOLO mode` banner does not trip :dialog", %{fp: fp} do
      banner = File.read!(fixture_path(["codex_cli", "idle_0135_yolo_banner.txt"]))
      assert {:ok, :idle} = Fingerprint.match(banner, fp)
    end

    test "real YOLO approval overlay still matches :dialog", %{fp: fp} do
      overlay = File.read!(fixture_path(["codex_cli", "dialog_trust_gate_yolo.txt"]))
      assert {:ok, :dialog} = Fingerprint.match(overlay, fp)
    end

    # Regression (docs/adr/0007-codex-0162-dialog-coverage.org): an idle Codex
    # 0.162 pane whose status line showed the branch `agy-ai-pair-yolo` and
    # whose transcript said "Git errors can bypass ..." read :dialog, holding
    # every wakeup, because the 0.162 footers (`⚠ 1 warning`, plain
    # `? for shortcuts`) were outside the unless_tail exemption. The fixture
    # is reconstructed from the observed screen. A busy screen with a dialog
    # word still reads :dialog by design; busy holds sends either way.
    test "0.162 idle composer tail exempts yolo branch name and `bypass` prose", %{fp: fp} do
      text = File.read!(fixture_path(["codex_cli", "idle_0162_yolo_branch_bypass_prose.txt"]))
      assert {:ok, :idle} = Fingerprint.match(text, fp)
    end

    # Real Codex 0.162 captures. The folder-trust dialog read :idle (its
    # `› 1. Trust and continue` line satisfied the idle prompt rule, so a
    # wakeup paste + Enter would have trusted the folder).
    test "0.162 folder-trust dialog matches :dialog", %{fp: fp} do
      text = File.read!(fixture_path(["codex_cli", "dialog_trust_folder_0162.txt"]))
      assert {:ok, :dialog} = Fingerprint.match(text, fp)
    end

    test "0.162 command-approval dialog matches :dialog", %{fp: fp} do
      text = File.read!(fixture_path(["codex_cli", "dialog_command_approval_0162.txt"]))
      assert {:ok, :dialog} = Fingerprint.match(text, fp)
    end

    # With the 0.162 idle composer tail at the bottom, transcript prose that
    # quotes or discusses approval wording leaves the pane idle.
    @approval_prose [
      "• The wrapper should never bypass permissions automatically.",
      "• A docs paragraph says do not bypass approvals.",
      "• The flag --dangerously-allow should stay disabled.",
      "  Quoting the overlay: \"bypass permissions for this session\" is not shown.",
      "  It said `--dangerously-allow enabled` in an old log; ignore that.",
      "  The dialog text \"Press enter to continue\" appears in the fixture.",
      "• We could bypass the check, but yolo merges and an Allow-list are out.",
      "  The flag --dangerously-bypass-approvals-and-sandbox stays off."
    ]
    @composer "\n› Ask Codex to do anything\n\n" <>
                "  gpt-5.5 high · ~/src/x · gpt-5.5 · yolo-bypass · Context 3% used\n" <>
                "  ? for shortcuts\n"

    test "approval wording in prose above a 0.162 idle tail stays :idle", %{fp: fp} do
      for line <- @approval_prose do
        assert {:ok, :idle} = Fingerprint.match(line <> "\n" <> @composer, fp), line
      end
    end
  end

  test "ANSI is stripped before matching" do
    fp = Fingerprint.load!(priv_path("claude_code.json"))
    raw_busy = "\e[31m* \e[1mCrunching... (esc to interrupt)\e[0m\n"
    assert {:ok, :busy} = Fingerprint.match(raw_busy, fp)
  end

  test "busy beats idle when both could fire" do
    fp = Fingerprint.load!(priv_path("claude_code.json"))
    # User typed "ctrl+c" into the prompt while busy — without the busy-first
    # rule, this would erroneously match :idle.
    confused = "user typed: ctrl+c\n* still working (esc to interrupt)\n"
    assert {:ok, :busy} = Fingerprint.match(confused, fp)
  end

  test "load returns error for missing file" do
    assert {:error, _} = Fingerprint.load("/nonexistent/path.json")
  end
end
