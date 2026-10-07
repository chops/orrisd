# NS-32.M.002 RB-2b: evaluated INSIDE the built release (`bin/ai_pair eval`), never activated.
# Prints two lines for rb2b_reads_check.exs: the release's own AiPair.Compat.reads/0 as JSON, and
# what AiPair.Compat.compatible?/2 says about a fresh inbox when the target declaration is the
# "reads" object stamped into this release's manifest (absent: nil).
root = List.to_string(:code.root_dir())

stamped =
  root
  |> Path.join("share/ai-pair/manifest.json")
  |> File.read!()
  |> JSON.decode!()
  |> Map.get("reads")

IO.puts("reads=" <> JSON.encode!(AiPair.Compat.reads()))

inbox = Path.join(System.tmp_dir!(), "rb2b-fresh-inbox")
File.mkdir_p!(inbox)
IO.puts("fresh=" <> inspect(AiPair.Compat.compatible?(AiPair.Compat.observe(inbox), stamped)))
