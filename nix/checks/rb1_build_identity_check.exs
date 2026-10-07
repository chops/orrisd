# NS-32.M.001 RB-1 C3: flake-check helpers for the stamped build identity (flake.nix checks rb1-n1, rb1-n4).
# Plain Elixir with the stdlib JSON module and :crypto; it never reuses the Nix hashString path, so the
# build_id it recomputes is independent of the stamping code. Exits nonzero with a reason on any mismatch.
#
#   n1 <package> <flake version> <rev or ""> <narHash> <flake_lock_sha256> <mix_deps_hash> <system>
#   n4 <package> <eval_output_file>

defmodule RB1BuildIdentityCheck do
  @keys ~w(build_id clean ipc_protocols name rollback_eligible source_nar_hash source_revision version)

  def main(["n1", package, version, rev, nar_hash, lock_sha, mix_hash, system]) do
    record = stamped(package)
    revision = if rev == "", do: nil, else: rev

    canonical =
      Enum.map_join(
        [
          {"name", "ai-pair"},
          {"version", version},
          {"source_nar_hash", nar_hash},
          {"flake_lock_sha256", lock_sha},
          {"mix_deps_hash", mix_hash},
          {"system", system},
          {"release_name", "ai_pair"},
          {"ipc_protocols", "1,2,3"}
        ],
        fn {key, value} -> "#{key}=#{value}\n" end
      )

    build_id = :sha256 |> :crypto.hash(canonical) |> Base.encode16(case: :lower)

    expect(Enum.sort(Map.keys(record)) == @keys, "N1: the record is not exactly the eight keys")
    expect(record["name"] == "ai-pair", "N1: name is not ai-pair")
    expect(record["version"] == version, "N1: version differs from the flake version")
    expect(record["build_id"] == build_id, "N1: build_id differs from the recomputed #{build_id}")

    expect(
      record["source_nar_hash"] == nar_hash,
      "N1: source_nar_hash differs from the flake narHash"
    )

    expect(record["source_revision"] == revision, "N1: source_revision differs from the flake rev")
    expect(record["clean"] == (revision != nil), "N1: clean disagrees with the flake rev")

    expect(
      record["rollback_eligible"] == (revision != nil),
      "N1: rollback_eligible disagrees with the flake rev"
    )

    expect(record["ipc_protocols"] == [1, 2, 3], "N1: ipc_protocols is not [1,2,3]")

    manifest = package |> Path.join("share/ai-pair/manifest.json") |> File.read!() |> JSON.decode!()

    expect(
      manifest["identity"] == record,
      "N1: the manifest identity differs from build-identity.json"
    )

    IO.puts("N1 ok build_id=#{build_id}")
  end

  def main(["n4", package, eval_output]) do
    record = stamped(package)
    lines = eval_output |> File.read!() |> String.split("\n", trim: true)

    expect(
      lines == ["root=" <> package, "read=ok", "equal=true"],
      "N4: the release reported #{inspect(lines)}"
    )

    IO.puts("N4 ok root=#{package} build_id=#{record["build_id"]}")
  end

  def main(args), do: fail("unknown arguments #{inspect(args)}")

  defp stamped(package) do
    path = Path.join(package, "share/ai-pair/build-identity.json")

    case File.read(path) do
      {:ok, bytes} -> JSON.decode!(bytes)
      {:error, reason} -> fail("#{path}: #{inspect(reason)}")
    end
  end

  defp expect(true, _message), do: :ok
  defp expect(false, message), do: fail(message)

  defp fail(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end
end

RB1BuildIdentityCheck.main(System.argv())
