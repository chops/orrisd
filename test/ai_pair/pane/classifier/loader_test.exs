defmodule AiPair.Pane.Classifier.LoaderTest do
  use ExUnit.Case, async: false

  alias AiPair.Pane.Classifier.Loader

  describe "known_agents/0" do
    test "lists the agents the loader can resolve" do
      assert "claude_code" in Loader.known_agents()
      assert "codex_cli" in Loader.known_agents()
    end
  end

  describe "load_for_agent/1 — happy path against priv/fingerprints" do
    test "claude_code returns a closure and a stable name" do
      assert {:ok, classifier, "fingerprint:claude_code"} = Loader.load_for_agent("claude_code")
      assert is_function(classifier, 1)
      # No matching content -> :unknown, proves the closure runs end-to-end.
      assert classifier.("nothing-anchor-shaped-here") in ~w(idle busy unknown)a
    end

    test "codex_cli returns a closure and a stable name" do
      assert {:ok, classifier, "fingerprint:codex_cli"} = Loader.load_for_agent("codex_cli")
      assert is_function(classifier, 1)
      assert classifier.("nothing-anchor-shaped-here") in ~w(idle busy unknown)a
    end
  end

  describe "load_for_agent/1 — fallbacks" do
    test "unknown agent returns {:fallback, :unknown_agent}" do
      assert {:fallback, :unknown_agent} = Loader.load_for_agent("not-a-real-agent")
    end

    test "corrupt fingerprint JSON returns {:fallback, {:load_failed, _}}" do
      tmp =
        Path.join(System.tmp_dir!(), "ai_pair_loader_corrupt_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "claude_code.json"), "{ this is not valid json")

      Application.put_env(:ai_pair, :fingerprint_dir, tmp)

      on_exit(fn ->
        Application.delete_env(:ai_pair, :fingerprint_dir)
        File.rm_rf!(tmp)
      end)

      assert {:fallback, {:load_failed, _reason}} = Loader.load_for_agent("claude_code")
    end

    test "missing fingerprint file returns {:fallback, {:load_failed, _}}" do
      tmp =
        Path.join(System.tmp_dir!(), "ai_pair_loader_missing_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)

      Application.put_env(:ai_pair, :fingerprint_dir, tmp)

      on_exit(fn ->
        Application.delete_env(:ai_pair, :fingerprint_dir)
        File.rm_rf!(tmp)
      end)

      assert {:fallback, {:load_failed, :enoent}} = Loader.load_for_agent("claude_code")
    end
  end
end
