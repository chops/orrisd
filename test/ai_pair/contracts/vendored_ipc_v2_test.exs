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

  SINCE orris `3684f53e` the vendored region itself declares a reciprocal pairing block
  ("Paired producer copy") whose keys are spelled like this repository's own
  (`paired_revision`, `paired_fixture_contract_hash`, `paired_fixture_count`) but which
  speak about the other direction. Two rows below exist only because of that: `declared/1`
  reads the PREAMBLE and requires exactly one declaration there, so a consumer key can
  never answer for a producer key; and the structural row no longer uses
  `paired_fixture_count` as a producer-only marker, because it is no longer one.
  """

  use ExUnit.Case, async: true

  @doc_path Path.expand("../../../docs/contracts/ipc-v2.org", __DIR__)
  @v1_doc_path Path.expand("../../../docs/contracts/ipc-v1.org", __DIR__)
  @fixture_dir Path.expand("../../fixtures/contracts/ipc/v2", __DIR__)
  @v1_fixture_dir Path.expand("../../fixtures/contracts/ipc/v1", __DIR__)

  @begin_sentinel "# BEGIN VENDORED orris docs/contracts/ipc-v2.org"
  @end_sentinel "# END VENDORED orris docs/contracts/ipc-v2.org"

  @orris_revision "880e7a3f8117c79114384c5f7682a70d44580046"
  @orris_sha256 "849589a85527357ed61643f50cdfe2a4ba32fec823e2dca28868ec77f44164cc"
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
      # Guard the actual delimiters, not prose: orris 880e7a3f line 92 legitimately
      # says VENDORED-REGION, so the former word-level refute rejected valid bytes.
      assert occurrences(doc, @begin_sentinel) == 1
      assert occurrences(doc, @end_sentinel) == 1
      assert byte_size(region) > 2_000
      refute String.contains?(region, @begin_sentinel)
      refute String.contains?(region, @end_sentinel)

      for token <- ~w(protocol_version delivered queued absent ambiguous conflict) do
        assert String.contains?(region, token), "the vendored region does not mention #{token}"
      end
    end

    test "the producer addenda stay outside the region so they cannot change its digest" do
      preamble = preamble()

      # The addenda are producer statements. Naming one of them inside the region
      # would mean the consumer document had been edited here, which the digest row
      # would catch -- but only after the fact, and only if the pins were not
      # recomputed at the same time. This row says it structurally.
      #
      # `paired_fixture_count` USED to be one of these markers and no longer is: at orris
      # `3684f53e` the consumer text declares its own reciprocal block with that key. A
      # marker must be producer-only in the CURRENT region, not in the one it was written
      # against, so the list is three strings that no consumer text has any reason to
      # carry: the addenda heading, a module function of this repository, and the
      # producer declaration of which repository the source is.
      for producer_only <- [
            "** Producer addenda",
            "ReceiptLog.valid_pane?/1",
            "- source_repository: =orris="
          ] do
        assert String.contains?(preamble, producer_only)

        refute String.contains?(vendored_region(), producer_only),
               "#{producer_only} is a producer statement and belongs outside the vendored region"
      end
    end

    test "a consumer pairing key inside the region never answers for a producer key" do
      region = vendored_region()

      # ANTI-VACUITY: the collision must really exist, or the rows below are a statement
      # about a document shape that is not the one shipped here.
      assert String.contains?(region, "** Paired producer copy")
      assert String.contains?(region, "- paired_fixture_contract_hash: ~")
      assert String.contains?(region, "- paired_fixture_count: ~16~")

      # The consumer names THIS repository, and the producer names the consumer. Reading
      # the whole file for `- <key>:` would let one stand in for the other; `declared/1`
      # reads the preamble, so these values are the producer declarations and no others.
      assert declared("paired_fixture_count") == "16"
      assert declared("paired_fixture_contract_hash") == @fixture_hash
      assert declared("source_revision") == @orris_revision

      # And the region's own reciprocal pins are a SNAPSHOT of this repository, not a
      # description of it: the producer document they digest is the one that existed
      # before this revision re-vendored. Naming the fact here keeps a later reader from
      # "repairing" the region to match the current file, which would break the digest.
      assert String.contains?(region, "- paired_repository: ~orrisd~")
      refute String.contains?(preamble(), "- paired_repository:")
    end

    test "the region states the pane grammar that governs this producer" do
      region = vendored_region()

      # WHY THIS IS PINNED. `AiPair.IPC.Delivery` echoes an identity only when the
      # identity predicate accepts it, and `Delivery.IPCIdentityGrammarTest` asserts
      # that the echo decision and the storage decision are the same decision. That
      # is a choice between two possible grammars, and it is this sentence -- not a
      # preference -- that makes it the right one. A re-vendoring that dropped the
      # sentence would leave the source change unexplained, so it fails here.
      assert String.contains?(region, "** Identity grammars and their refusals")

      assert String.contains?(
               region,
               "~pane_id~ is ~%~ followed by 1..128 characters from ~[a-zA-Z0-9_]~. This is the"
             )

      assert String.contains?(region, "GOVERNING grammar")

      for token <- ~w(invalid_msg_id invalid_pane_id) do
        assert String.contains?(region, token),
               "#{token} was carried by the producer addenda until orris e5da392e named it; " <>
                 "a region without it means the addendum, not the contract, is the source"
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

  defp preamble do
    [preamble, _] = String.split(File.read!(@doc_path), @begin_sentinel, parts: 2)
    preamble
  end

  # `- <key>: =<value>=` inside the paired-revision block, read from the PREAMBLE only.
  #
  # Scoped deliberately. The vendored region declares the consumer's reciprocal block with
  # keys of the same shape, so a whole-file read would resolve some keys by position --
  # the answer would depend on which block comes first in the file rather than on which
  # repository is speaking. Exactly one declaration is required, so a duplicated or
  # deleted producer key fails here instead of silently resolving to the survivor.
  defp declared(key) do
    regex = Regex.compile!("^- " <> Regex.escape(key) <> ": =?([^=\n]+)=?$", "m")

    case Regex.scan(regex, preamble()) do
      [[_, value]] ->
        String.trim(value)

      [] ->
        flunk("the document preamble declares no #{key}")

      many ->
        flunk("the document preamble declares #{key} #{length(many)} times: #{inspect(many)}")
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
