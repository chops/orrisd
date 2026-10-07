defmodule AiPair.Contracts.VendoredIPCV3Test do
  @moduledoc """
  The drift control for the vendored v3 contract text (`docs/contracts/ipc-v3.org`, NS-15.G.002
  B1a-2), on the pattern of `vendored_ipc_v2_test.exs`: the region between the two sentinel lines
  is the consumer's bytes at the pinned revision, its digest is pinned in BOTH the document and
  this module, and the vendored fixture set hashes to the pinned value under the v1 rule.

  LIMIT: no row can see the consumer repository; what is detected is a change made HERE.
  """

  use ExUnit.Case, async: true

  @doc_path Path.expand("../../../docs/contracts/ipc-v3.org", __DIR__)
  @fixture_dir Path.expand("../../fixtures/contracts/ipc/v3", __DIR__)

  @begin_sentinel "# BEGIN VENDORED orris docs/contracts/ipc-v3.org"
  @end_sentinel "# END VENDORED orris docs/contracts/ipc-v3.org"

  @orris_revision "816f411fd547115fd748a0e8584a8c3a972b5e7a"
  @orris_sha256 "b90af20d328823d64d2fbe7e39ac185101fbecef25cbaebb562e885b8afeb01c"
  @fixture_hash "56cbc3257efa181fa4c9715528c4d02eb15dcadc4c101d373035c8032f65c592"
  @fixture_count 59

  test "the vendored region is exactly the pinned consumer bytes, pinned twice" do
    assert digest(vendored_region()) == @orris_sha256
    assert declared("source_sha256") == @orris_sha256
    assert declared("source_revision") == @orris_revision
    assert declared("source_repository") == "orris"
    assert declared("source_path") == "docs/contracts/ipc-v3.org"
  end

  test "the region is delimited exactly once and really holds the version 3 contract" do
    doc = File.read!(@doc_path)
    region = vendored_region()

    assert occurrences(doc, @begin_sentinel) == 1
    assert occurrences(doc, @end_sentinel) == 1
    assert byte_size(region) > 2_000

    for token <- ~w(pane_identity pane_identity_unavailable registration_id identity_core.json) do
      assert String.contains?(region, token), "the vendored region does not mention #{token}"
    end
  end

  test "the vendored fixture set hashes to the pinned value and is complete" do
    paths = @fixture_dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort()
    assert length(paths) == @fixture_count
    assert declared("paired_fixture_count") == Integer.to_string(@fixture_count)

    payload = Enum.map(paths, fn path -> [Path.basename(path), 0, File.read!(path), 0] end)
    assert digest(payload) == @fixture_hash
    assert declared("paired_fixture_contract_hash") == @fixture_hash

    assert @fixture_dir |> Path.join("CONTRACT_HASH") |> File.read!() |> String.trim() ==
             @fixture_hash
  end

  defp vendored_region do
    [_preamble, rest] = String.split(File.read!(@doc_path), @begin_sentinel <> "\n", parts: 2)
    [region, _tail] = String.split(rest, @end_sentinel <> "\n", parts: 2)
    region
  end

  defp preamble do
    [preamble, _] = String.split(File.read!(@doc_path), @begin_sentinel, parts: 2)
    preamble
  end

  defp declared(key) do
    regex = Regex.compile!("^- " <> Regex.escape(key) <> ": =?([^=\n]+)=?$", "m")

    case Regex.scan(regex, preamble()) do
      [[_, value]] -> String.trim(value)
      other -> flunk("the preamble declares #{key} #{length(other)} times")
    end
  end

  defp occurrences(doc, needle), do: length(String.split(doc, needle)) - 1
  defp digest(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
