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
