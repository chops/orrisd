# NS-32.M.002 RB-2b: flake-check helpers for the release manifest's "reads" stamp (flake.nix checks
# rb2b-n1, rb2b-n2, rb2b-n3). Plain Elixir with the stdlib JSON module. The source of truth is the
# BUILT release's own AiPair.Compat.reads/0, printed by rb2b_eval.exs; the stamp must equal it.
# Exits nonzero with a reason on any mismatch.
#
#   n1 <package> <eval_output_file>   the stamp equals reads/0 as canonical JSON
#   n2 <package> <eval_output_file>   the stamp is exactly a declaration and supports a fresh inbox
#   n3 <package> <eval_output_file>   negative control: a drifted synthetic stamp is refused by n1's comparison

defmodule RB2BReadsCheck do
  @dims ~w(effects lineage pane_intent payloads receipts)

  def main(["n1", package, eval_output]) do
    {reads, _fresh} = evaluated(eval_output)

    case compare(manifest(package), reads) do
      :ok -> IO.puts("N1 ok reads=" <> canonical(reads))
      {:error, message} -> fail(message)
    end
  end

  def main(["n2", package, eval_output]) do
    {_reads, fresh} = evaluated(eval_output)
    stamp = Map.get(manifest(package), "reads")

    expect(is_map(stamp), "N2: the manifest has no reads stamp")

    expect(
      Enum.sort(Map.keys(stamp)) == Enum.sort(["effects_hold_aware" | @dims]),
      "N2: the stamp is not exactly the declaration keys: #{inspect(Map.keys(stamp))}"
    )

    expect(Enum.all?(@dims, &is_list(stamp[&1])), "N2: a dimension of the stamp is not a list")
    expect(is_boolean(stamp["effects_hold_aware"]), "N2: effects_hold_aware is not a boolean")
    expect(fresh == ":supported", "N2: a fresh inbox against the stamp gave #{fresh}")
    IO.puts("N2 ok fresh=" <> fresh)
  end

  def main(["n3", _package, eval_output]) do
    {reads, _fresh} = evaluated(eval_output)
    [_ | _] = receipts = reads["receipts"]
    drifted = %{"reads" => Map.put(reads, "receipts", Enum.drop(receipts, -1))}

    case compare(drifted, reads) do
      {:error, "N1: the stamped reads differ from the release's AiPair.Compat.reads/0" <> _} ->
        IO.puts("N3 ok: a drifted stamp is refused")

      other ->
        fail("N3: a drifted stamp was not refused by name: #{inspect(other)}")
    end
  end

  def main(args), do: fail("unknown arguments #{inspect(args)}")

  defp compare(manifest, reads) do
    case Map.fetch(manifest, "reads") do
      :error ->
        {:error, "N1: the manifest has no reads stamp"}

      {:ok, stamp} ->
        if canonical(stamp) == canonical(reads),
          do: :ok,
          else:
            {:error,
             "N1: the stamped reads differ from the release's AiPair.Compat.reads/0: stamp " <>
               canonical(stamp) <> " source " <> canonical(reads)}
    end
  end

  # Canonical JSON: object keys sorted, no whitespace.
  defp canonical(map) when is_map(map) do
    body =
      map
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.map_join(",", fn {key, value} -> JSON.encode!(key) <> ":" <> canonical(value) end)

    "{" <> body <> "}"
  end

  defp canonical(list) when is_list(list), do: "[" <> Enum.map_join(list, ",", &canonical/1) <> "]"
  defp canonical(value), do: JSON.encode!(value)

  defp evaluated(eval_output) do
    case eval_output |> File.read!() |> String.split("\n", trim: true) do
      ["reads=" <> reads, "fresh=" <> fresh] -> {JSON.decode!(reads), fresh}
      lines -> fail("the release evaluation reported #{inspect(lines)}")
    end
  end

  defp manifest(package) do
    path = Path.join(package, "share/ai-pair/manifest.json")

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

RB2BReadsCheck.main(System.argv())
