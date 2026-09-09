defmodule AiPair.CalibratorTest do
  @moduledoc """
  Lightweight unit tests for the otel-instrumented fast-fail paths in
  `AiPair.Calibrator`. The full capture/verify pipeline drives a real
  tmux server + TUI subprocess and is exercised by the manual
  calibration workflow rather than ExUnit.
  """

  use ExUnit.Case, async: false

  import AiPair.Test.OtelHelper

  alias AiPair.Calibrator

  test "capture/2 emits calibrator.capture span with unknown_tui reason on bad input" do
    setup_otel_capture()

    assert {:error, _} = Calibrator.capture(["definitely-not-a-tui"], log_fn: fn _ -> :ok end)

    assert {:ok, span} = assert_span(name: "calibrator.capture")
    attrs = span_attrs(span)
    assert attrs["calibrator.tuis"] == "definitely-not-a-tui"
    assert attrs["calibrator.tui_count"] == 1
    assert attrs["calibrator.error_reason"] == "unknown_tui"
  end

  test "verify/2 emits calibrator.verify span with strict + counts on a clean run" do
    setup_otel_capture()

    fixture_root =
      Path.join(System.tmp_dir!(), "ai_pair_cal_verify_#{System.unique_integer([:positive])}")

    fingerprint_root =
      Path.join(System.tmp_dir!(), "ai_pair_cal_fp_#{System.unique_integer([:positive])}")

    File.mkdir_p!(fingerprint_root)

    File.write!(
      Path.join(fingerprint_root, "claude_code.json"),
      ~s({"states":{"idle":{"any":[]},"busy":{"any":[]}},"precedence":["busy","idle"]})
    )

    on_exit(fn ->
      File.rm_rf!(fixture_root)
      File.rm_rf!(fingerprint_root)
    end)

    assert {:ok, %{passed: 0, mismatched: []}} =
             Calibrator.verify(["claude_code"],
               log_fn: fn _ -> :ok end,
               fixture_root: fixture_root,
               fingerprint_root: fingerprint_root
             )

    assert {:ok, span} = assert_span(name: "calibrator.verify")
    attrs = span_attrs(span)
    assert attrs["calibrator.strict"] == false
    assert attrs["calibrator.passed"] == 0
    assert attrs["calibrator.mismatch_count"] == 0
    refute Map.has_key?(attrs, "calibrator.error_reason")

    assert {:ok, vf_span} = assert_span(name: "calibrator.verify_fixtures")
    vf_attrs = span_attrs(vf_span)
    assert vf_attrs["calibrator.tui"] == "claude_code"
    assert vf_attrs["calibrator.fixture_count"] == 0
  end

  test "verify/2 emits hard_errors reason when fingerprint file is missing" do
    setup_otel_capture()

    fixture_root =
      Path.join(System.tmp_dir!(), "ai_pair_cal_missing_#{System.unique_integer([:positive])}")

    fingerprint_root =
      Path.join(System.tmp_dir!(), "ai_pair_cal_missingfp_#{System.unique_integer([:positive])}")

    File.mkdir_p!(fingerprint_root)

    on_exit(fn ->
      File.rm_rf!(fixture_root)
      File.rm_rf!(fingerprint_root)
    end)

    assert {:error, {:hard_errors, _}} =
             Calibrator.verify(["claude_code"],
               log_fn: fn _ -> :ok end,
               fixture_root: fixture_root,
               fingerprint_root: fingerprint_root
             )

    assert {:ok, span} = assert_span(name: "calibrator.verify")
    attrs = span_attrs(span)
    assert attrs["calibrator.error_reason"] == "hard_errors"

    assert {:ok, vf_span} = assert_span(name: "calibrator.verify_fixtures")
    vf_attrs = span_attrs(vf_span)
    assert vf_attrs["calibrator.error_reason"] == "fingerprint_load"
  end
end
