defmodule AiPair.Contracts.IPCContractHashTest do
  @moduledoc """
  Freezes the IPC v1 fixture set under NS-39.A.000/.001: the fifteen files, their exact
  names and their pinned content hash. The hash is pinned HERE as well as in
  `CONTRACT_HASH`, because a change that edited a fixture and recomputed the file together
  would satisfy a self-comparison and still break the Orris consumer, which pins the same
  bytes. v1 covers `ping`, `send` and `pane_status` only: `attach_pane` and `detach_pane`
  have no frozen v1 fixture, which is why the durable attach/detach contract
  (`docs/contracts/durable-attach-detach.org`) can add reply members without touching this
  set. That direction is guarded by
  `test/ai_pair/contracts/durable_ipc_contract_test.exs`.
  """

  use ExUnit.Case, async: true

  @fixture_dir Path.expand("../../fixtures/contracts/ipc/v1", __DIR__)
  @hash_path Path.join(@fixture_dir, "CONTRACT_HASH")
  @pinned_hash "f1cacf8b53fdd1db37ec968e5476081250804e9c6a4d615215d47d9b77894213"

  @fixtures ~w(
    pane_status.error.missing_pane_id.json
    pane_status.error.pane_dead.json
    pane_status.error.pane_not_found.json
    pane_status.ok.json
    ping.ok.json
    send.error.missing_pane_id.json
    send.error.missing_text.json
    send.error.oversize.json
    send.error.pane_dead.json
    send.error.pane_not_found.json
    send.error.paste_failed.json
    send.error.queue_full.json
    send.error.send_timeout.json
    send.queued.json
    send.sent.json
  )

  test "the IPC v1 fixture set is exactly the fifteen frozen files" do
    paths = fixture_paths()

    assert Enum.map(paths, &Path.basename/1) == @fixtures
    assert length(@fixtures) == 15
  end

  test "the IPC v1 fixture set matches its pinned content hash" do
    paths = fixture_paths()

    assert paths != [], "IPC v1 contract fixture set is missing"
    assert File.regular?(@hash_path), "IPC v1 CONTRACT_HASH is missing"

    payload =
      Enum.map(paths, fn path ->
        [Path.basename(path), 0, File.read!(path), 0]
      end)

    actual = :sha256 |> :crypto.hash(payload) |> Base.encode16(case: :lower)
    expected = @hash_path |> File.read!() |> String.trim()

    assert actual == expected
    assert actual == @pinned_hash
    assert expected == @pinned_hash
  end

  defp fixture_paths, do: @fixture_dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort()
end
