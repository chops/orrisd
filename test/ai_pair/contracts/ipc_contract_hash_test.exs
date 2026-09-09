defmodule AiPair.Contracts.IPCContractHashTest do
  use ExUnit.Case, async: true

  @fixture_dir Path.expand("../../fixtures/contracts/ipc/v1", __DIR__)
  @hash_path Path.join(@fixture_dir, "CONTRACT_HASH")

  test "the IPC v1 fixture set matches its pinned content hash" do
    paths = Path.wildcard(Path.join(@fixture_dir, "*.json")) |> Enum.sort()

    assert paths != [], "IPC v1 contract fixture set is missing"
    assert File.regular?(@hash_path), "IPC v1 CONTRACT_HASH is missing"

    payload =
      Enum.map(paths, fn path ->
        [Path.basename(path), 0, File.read!(path), 0]
      end)

    actual = :sha256 |> :crypto.hash(payload) |> Base.encode16(case: :lower)
    expected = @hash_path |> File.read!() |> String.trim()

    assert actual == expected
  end
end
