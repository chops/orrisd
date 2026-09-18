defmodule AiPair.Contracts.VendoredIPCV2Test do
  @moduledoc """
  The drift control for the vendored v2 contract text (`docs/contracts/ipc-v2.org`).

  This repository is the producer of the v2 frames and, until that file existed, shipped
  the v2 fixture bytes without the document that describes them. The contract text is
  vendored verbatim from the consumer rather than restated, because a restatement is a
  second contract that drifts silently; the copy is delimited by two sentinel comment
  lines so that the producer addenda around it cannot perturb its digest.

  The pinned digest is stated in BOTH the document and this module, for the reason
  `ipc_contract_hash_test.exs` states about the v1 fixture hash: a change that edited the
  copy and recomputed the digest in the same file would satisfy a self-comparison and
  still break the consumer that pins the original bytes.

  LIMIT, stated rather than implied. No row here can see a change made in the consumer
  repository, because the gate has no access to it. What these rows detect is a change
  made HERE: an edited copy, disagreeing pins, a fixture set that no longer hashes to the
  pinned value, or an inventory that no longer matches the directory. Adopting a new
  consumer revision is a deliberate re-vendoring that updates the revision, the digest
  and the pin below together.
  """

  use ExUnit.Case, async: true

  @doc_path Path.expand("../../../docs/contracts/ipc-v2.org", __DIR__)
  @v1_doc_path Path.expand("../../../docs/contracts/ipc-v1.org", __DIR__)
  @fixture_dir Path.expand("../../fixtures/contracts/ipc/v2", __DIR__)
  @v1_fixture_dir Path.expand("../../fixtures/contracts/ipc/v1", __DIR__)

  @begin_sentinel "# BEGIN VENDORED orris docs/contracts/ipc-v2.org"
  @end_sentinel "# END VENDORED orris docs/contracts/ipc-v2.org"

  @orris_revision "cab4565b9246666fc4cc86d729e664a15e6229f0"
  @orris_sha256 "0263abf21b62cf70a1a63f6ca77c92ba8eca38aa2c62cb16967b4e6546ddbda3"
  @fixture_hash "78c2f64240c3c5c9da60425c65c498974a2a81c8adb3e68e0bef28613c1707dc"
  @v1_fixture_hash "f1cacf8b53fdd1db37ec968e5476081250804e9c6a4d615215d47d9b77894213"

  @fixtures ~w(
    ping.ok.json
    reconcile.absent.json
    reconcile.absent.not_delivered.json
    reconcile.ambiguous.json
    reconcile.conflict.json
    reconcile.delivered.json
    reconcile.error.missing_payload_hash.json
    reconcile.queued.json
    send.duplicate.ambiguous.json
    send.duplicate.delivered.json
    send.duplicate.pending.json
    send.duplicate.queued.json
    send.error.conflict.json
    send.error.missing_msg_id.json
    send.queued.json
    send.sent.json
  )

  describe "the vendored contract text" do
    test "the vendored region is exactly the pinned consumer bytes" do
      assert digest(vendored_region()) == @orris_sha256

      assert declared("source_sha256") == @orris_sha256,
             "the document and this module pin the same digest independently; one edited " <>
               "without the other is drift, not a fix"
    end

    test "the copy names the consumer revision it was taken from" do
      assert declared("source_revision") == @orris_revision
      assert Regex.match?(~r/\A[0-9a-f]{40}\z/, declared("source_revision"))
      assert declared("source_repository") == "orris"
      assert declared("source_path") == "docs/contracts/ipc-v2.org"
    end

    test "the region is delimited exactly once and really holds the contract" do
      doc = File.read!(@doc_path)
      region = vendored_region()

      # ANTI-VACUITY. An extractor that silently returned "" would make the digest row a
      # statement about the empty string, and a second pair of sentinels would make
      # "the vendored region" ambiguous.
      assert occurrences(doc, @begin_sentinel) == 1
      assert occurrences(doc, @end_sentinel) == 1
      assert byte_size(region) > 2_000
      refute String.contains?(region, "VENDORED")

      for token <- ~w(protocol_version delivered queued absent ambiguous conflict) do
        assert String.contains?(region, token), "the vendored region does not mention #{token}"
      end
    end

    test "the producer addenda stay outside the region so they cannot change its digest" do
      [preamble, _] = String.split(File.read!(@doc_path), @begin_sentinel, parts: 2)

      for token <- ~w(invalid_msg_id invalid_pane_id) do
        assert String.contains?(preamble, token),
               "#{token} is producer-emitted and unnamed by the consumer text; the addendum " <>
                 "is where it belongs"

        refute String.contains?(vendored_region(), token)
      end
    end
  end

  describe "the fixture set the document pairs with" do
    test "the pinned hash is the hash of the fixtures this repository ships" do
      paths = @fixture_dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort()
      payload = Enum.map(paths, fn path -> [Path.basename(path), 0, File.read!(path), 0] end)

      assert paths != []
      assert digest(payload) == @fixture_hash
      assert read_hash(@fixture_dir) == @fixture_hash

      assert declared("paired_fixture_contract_hash") == @fixture_hash,
             "the contract text names the fixture hash, so editing a fixture without " <>
               "re-vendoring fails here as well as in the consumer"
    end

    test "the inventory the document names is exactly the shipped set" do
      named = documented_fixtures()
      shipped = @fixture_dir |> Path.join("*.json") |> Path.wildcard() |> Enum.map(&Path.basename/1)

      assert named != [], "the inventory parser found nothing; it, not the document, is wrong"
      assert named == @fixtures
      assert Enum.sort(shipped) == @fixtures
      assert declared("paired_fixture_count") == "16"
      assert length(@fixtures) == 16
    end
  end

  describe "the v1 contract carries the same pairing" do
    test "it names the consumer revision and the v1 fixture hash it was measured against" do
      v1 = File.read!(@v1_doc_path)

      assert String.contains?(v1, @orris_revision)
      assert String.contains?(v1, @v1_fixture_hash)
      assert read_hash(@v1_fixture_dir) == @v1_fixture_hash
    end
  end

  # ===== helpers =====

  defp vendored_region do
    [_preamble, rest] = String.split(File.read!(@doc_path), @begin_sentinel <> "\n", parts: 2)
    [region, _tail] = String.split(rest, @end_sentinel <> "\n", parts: 2)
    region
  end

  # `- <key>: =<value>=` inside the paired-revision block.
  defp declared(key) do
    regex = Regex.compile!("^- " <> Regex.escape(key) <> ": =?([^=\n]+)=?$", "m")

    case Regex.run(regex, File.read!(@doc_path)) do
      [_, value] -> String.trim(value)
      nil -> flunk("the document declares no #{key}")
    end
  end

  # Only the inventory list after the vendored region; the consumer table inside the
  # region names fixtures with different markup and is deliberately not read here.
  defp documented_fixtures do
    [_, tail] = String.split(File.read!(@doc_path), @end_sentinel, parts: 2)

    ~r/^- =([a-z0-9_.]+\.json)=$/m
    |> Regex.scan(tail)
    |> Enum.map(fn [_, name] -> name end)
    |> Enum.sort()
  end

  defp occurrences(haystack, needle), do: length(String.split(haystack, needle)) - 1

  defp read_hash(dir), do: dir |> Path.join("CONTRACT_HASH") |> File.read!() |> String.trim()

  defp digest(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
