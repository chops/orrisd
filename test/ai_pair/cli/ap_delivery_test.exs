defmodule AiPair.CLI.ApDeliveryTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../..", __DIR__) |> Path.join("nix/files/ap.sh")

  for verb <- ["ping", "reconcile", "send"] do
    test "ap forwards #{verb} arguments and stdin unchanged" do
      root = Path.join(System.tmp_dir!(), "ap-wire-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      File.cp!(@script, Path.join(root, "ap"))
      client = Path.join(root, "ai-pair")
      File.write!(client, "#!/usr/bin/env bash\nprintf '%s\\0' \"$@\"\ncat\n")
      File.chmod!(client, 0o700)
      args = [unquote(verb), "%test", "--protocol-version", "2", "--msg-id", "snd_example"]
      input = Path.join(root, "stdin")
      File.write!(input, "literal delivery input\n")

      {out, status} =
        System.cmd(
          "bash",
          [
            "-c",
            "exec bash \"$1\" \"${@:3}\" < \"$2\"",
            "ap-test",
            Path.join(root, "ap"),
            input | args
          ],
          env: [{"AI_PAIR_PROJECT_DIR", root}]
        )

      assert status == 0
      assert out == Enum.join(args, <<0>>) <> <<0>> <> "literal delivery input\n"
    end
  end
end
