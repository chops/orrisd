# NS-32.M.001 RB-1 C3 N4: evaluated INSIDE the built release (`bin/ai_pair eval`), never activated.
# Prints three lines for rb1_build_identity_check.exs n4: the release root, whether the default reader
# accepted the record there, and whether it equals the stamped file at that root.
root = List.to_string(:code.root_dir())
IO.puts("root=" <> root)

case AiPair.BuildIdentity.read(AiPair.BuildIdentity.release_root()) do
  {:ok, record} ->
    stamped =
      root |> Path.join("share/ai-pair/build-identity.json") |> File.read!() |> JSON.decode!()

    IO.puts("read=ok")
    IO.puts("equal=#{record == stamped}")

  other ->
    IO.puts("read=" <> inspect(other))
end
