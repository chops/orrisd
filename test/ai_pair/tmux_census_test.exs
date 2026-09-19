defmodule AiPair.TmuxCensusTest do
  # R04 slice S4: the strict census and the session-option calls, driven through
  # a fake `tmux` in the style of AiPair.TmuxPaneListCodecTest. No tmux server of
  # any kind is started here: every row hands the adapter an owned Bash stub that
  # records its argv (NUL separated, one file per invocation) and prints canned
  # bytes with a canned exit status. Argv exactness, the parser and the failure
  # mapping are therefore measured against bytes this file controls, and the
  # frozen fixture under test/fixtures/tmux/ pins the format and its decoding.
  use ExUnit.Case, async: true

  alias AiPair.Tmux

  @fixture_dir Path.expand("../fixtures/tmux", __DIR__)
  @option "@ai_pair_session_incarnation"

  # An owned fake `tmux`. `output` is printed byte for byte (hex escaped into a
  # Bash printf format, so tabs, quotes and non-ASCII bytes survive) on the
  # chosen stream, then the stub exits with `status`. Every invocation's argv is
  # written to `<dir>/argv.<n>` as NUL-terminated elements.
  defp fake_tmux!(output, opts \\ []) do
    status = Keyword.get(opts, :status, 0)
    stream = Keyword.get(opts, :stream, :stdout)
    socket_name = Keyword.get(opts, :socket_name)

    dir = Path.join(System.tmp_dir!(), "tmux_census_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "calls"), "0")

    redirect = if stream == :stderr, do: " >&2", else: ""
    bin = Path.join(dir, "tmux")

    File.write!(bin, """
    #!/bin/bash
    here=$(cd "$(dirname "$0")" && pwd -P)
    n=$(<"$here/calls")
    n=$((n + 1))
    printf '%s' "$n" >"$here/calls"
    printf '%s\\0' "$@" >"$here/argv.$n"
    printf '#{hex_escape(output)}'#{redirect}
    exit #{status}
    """)

    File.chmod!(bin, 0o700)

    name = String.to_atom("tmux_census_#{System.unique_integer([:positive])}")
    opts = [name: name, tmux_bin: bin, socket_name: socket_name]
    start_supervised!(Supervisor.child_spec({Tmux, opts}, id: name))
    {name, dir}
  end

  defp hex_escape(bytes) do
    for <<b <- bytes>>, into: "", do: "\\x" <> Base.encode16(<<b>>, case: :lower)
  end

  defp argv!(dir, n \\ 1) do
    dir
    |> Path.join("argv.#{n}")
    |> File.read!()
    |> :binary.split(<<0>>, [:global])
    |> List.delete_at(-1)
  end

  defp calls!(dir), do: dir |> Path.join("calls") |> File.read!() |> String.to_integer()

  defp fixture!(name), do: @fixture_dir |> Path.join(name) |> File.read!()

  defp expected_observations! do
    "observe_panes.expected.json"
    |> fixture!()
    |> Jason.decode!()
    |> Enum.map(fn row -> Map.new(row, fn {k, v} -> {String.to_existing_atom(k), v} end) end)
  end

  describe "observe_panes/1 argv" do
    test "is list-panes -a -F <frozen format>, nothing else, with no socket flag" do
      {server, dir} = fake_tmux!("")

      assert {:ok, []} = Tmux.observe_panes(server)
      assert argv!(dir) == ["list-panes", "-a", "-F", fixture!("observe_panes.format.txt")]
      assert calls!(dir) == 1
    end

    test "prepends -L <socket_name> when the adapter is scoped to a server" do
      {server, dir} = fake_tmux!("", socket_name: "census_sock")

      assert {:ok, []} = Tmux.observe_panes(server)
      assert argv!(dir) == ["-L", "census_sock", "list-panes", "-a", "-F", Tmux.observe_format()]
    end

    test "the format is the frozen fixture and its arity is stated as 8" do
      assert Tmux.observe_format() == fixture!("observe_panes.format.txt")
      assert Tmux.observation_arity() == 8
      # Every free-text field is percent escaped by tmux; no tab is anywhere in
      # the format, so a C locale cannot change how many fields a row has.
      refute String.contains?(Tmux.observe_format(), "\t")
      escapes = String.split(Tmux.observe_format(), "s/%/%25/;s/[|]/%7C/:")
      assert length(escapes) == 4, "three free-text fields must carry the percent escape"
    end

    test "the existing lossy census argv is unchanged (additive control)" do
      {server, dir} = fake_tmux!("")

      assert {:ok, []} = Tmux.list_panes(server)

      assert argv!(dir) == [
               "list-panes",
               "-a",
               "-F",
               "\#{pane_id}|\#{s/%/%25/;s/[|]/%7C/:session_name}|\#{window_index}|" <>
                 "\#{pane_index}|\#{pane_pid}|\#{s/%/%25/;s/[|]/%7C/:pane_current_command}"
             ]
    end
  end

  describe "observe_panes/1 parsing" do
    test "decodes the frozen fixture bytes into exactly the frozen structure" do
      {server, _dir} = fake_tmux!(fixture!("observe_panes.raw.txt"))

      assert {:ok, observations} = Tmux.observe_panes(server)
      assert observations == expected_observations!()

      # The fixture covers what the format must survive: spaces, double quotes,
      # an apostrophe, a literal tab, non-ASCII UTF-8, and both percent escapes.
      [_plain, escaped, unicode] = observations
      assert escaped.session_name == "pair | %z name"
      assert escaped.command == ~s(bash -lc "echo hi%7Cx%25y")
      assert escaped.path == "/synthetic/path with spaces/and|bar"
      assert unicode.session_name == "café 日本\ttab 'q'"
      assert unicode.path == "/synthetic/über/路径"
      assert Enum.all?(observations, &(map_size(&1) == Tmux.observation_arity()))
    end

    test "session_id is the stable $N id, separate from the reusable session name" do
      {server, _dir} = fake_tmux!("%pane-a|$7|renamed twice|0|0|123|zsh|/synthetic/p\n")

      assert {:ok, [obs]} = Tmux.observe_panes(server)
      assert obs.session_id == "$7"
      assert obs.session_name == "renamed twice"
      assert obs.pane_id == "%pane-a"
      assert obs.window_index == 0 and obs.pane_index == 0 and obs.pane_pid == 123
    end

    test "a doubly escaped field decodes once, never recursively" do
      # tmux escapes a literal "%7C" in a name as "%257C"; decoding must give
      # back "%7C", not "|".
      {server, _dir} = fake_tmux!("%pane-a|$1|n%257Cx%2525y|0|0|1|c|/synthetic\n")

      assert {:ok, [obs]} = Tmux.observe_panes(server)
      assert obs.session_name == "n%7Cx%25y"
    end

    test "a literal tab inside a field is content, not a separator" do
      {server, _dir} = fake_tmux!("%pane-a|$1|a\tb|0|0|1|c\td|/synthetic/e\tf\n")

      assert {:ok, [obs]} = Tmux.observe_panes(server)
      assert obs.session_name == "a\tb"
      assert obs.command == "c\td"
      assert obs.path == "/synthetic/e\tf"
    end

    test "empty output is an empty census, a different claim from a failure" do
      {server, _dir} = fake_tmux!("")

      assert {:ok, []} = Tmux.observe_panes(server)
    end

    test "a failing tmux invocation is the error map, not a census" do
      {server, _dir} = fake_tmux!("no server running on /synthetic/sock\n", status: 1)

      assert {:error, %{cmd: [_bin, "list-panes", "-a", "-F", _fmt], status: 1, stderr: stderr}} =
               Tmux.observe_panes(server)

      assert stderr == "no server running on /synthetic/sock\n"
    end
  end

  describe "observe_panes/1 malformed rows" do
    test "a short row is a typed row_arity error, never a dropped row or {:ok, []}" do
      {server, _dir} = fake_tmux!("%pane-a|$1|test|0|0|123|zsh\n")

      result = Tmux.observe_panes(server)

      refute match?({:ok, _}, result), "a malformed census must not look like a readable one"
      assert {:error, {:row_arity, 8, 7, 0}} = result
    end

    test "a truncated second row fails the whole census with its index" do
      well_formed = "%pane-a|$1|test|0|0|123|zsh|/synthetic/project\n"
      {server, _dir} = fake_tmux!(well_formed <> "%pane-b|$1|test|0")

      result = Tmux.observe_panes(server)

      refute match?({:ok, [_]}, result), "a partial census must not be reported as complete"
      assert {:error, {:row_arity, 8, 4, 1}} = result
    end

    test "a blank line is a row of the wrong width, not skipped" do
      {server, _dir} = fake_tmux!("%pane-a|$1|test|0|0|123|zsh|/synthetic\n\n")

      assert {:error, {:row_arity, 8, 1, 1}} = Tmux.observe_panes(server)
    end

    test "a pane_pid that is only partly a number is malformed, not coerced" do
      {server, _dir} = fake_tmux!("%pane-a|$1|test|0|0|12abc|zsh|/synthetic\n")

      assert {:error, {:malformed_pid, "12abc"}} = Tmux.observe_panes(server)
    end

    test "a zero pane_pid identifies no process" do
      {server, _dir} = fake_tmux!("%pane-a|$1|test|0|0|0|zsh|/synthetic\n")

      assert {:error, {:malformed_pid, "0"}} = Tmux.observe_panes(server)
    end

    test "a non-decimal index names its field" do
      {server, _dir} = fake_tmux!("%pane-a|$1|test|x|0|1|zsh|/synthetic\n")
      assert {:error, {:malformed_index, :window_index, "x"}} = Tmux.observe_panes(server)

      {server, _dir} = fake_tmux!("%pane-a|$1|test|0|-1|1|zsh|/synthetic\n")
      assert {:error, {:malformed_index, :pane_index, "-1"}} = Tmux.observe_panes(server)
    end

    test "an empty text field is a field tmux did not answer" do
      {server, _dir} = fake_tmux!("%pane-a|$1||0|0|1|zsh|/synthetic\n")
      assert {:error, {:malformed_text, :session_name, ""}} = Tmux.observe_panes(server)

      {server, _dir} = fake_tmux!("%pane-a|$1|test|0|0|1||/synthetic\n")
      assert {:error, {:malformed_text, :command, ""}} = Tmux.observe_panes(server)

      {server, _dir} = fake_tmux!("%pane-a|$1|test|0|0|1|zsh|\n")
      assert {:error, {:malformed_text, :path, ""}} = Tmux.observe_panes(server)
    end

    test "a pane id without % or a session id without $ is malformed" do
      {server, _dir} = fake_tmux!("pane-a|$1|test|0|0|1|zsh|/synthetic\n")
      assert {:error, {:malformed_text, :pane_id, "pane-a"}} = Tmux.observe_panes(server)

      {server, _dir} = fake_tmux!("%pane-a|1|test|0|0|1|zsh|/synthetic\n")
      assert {:error, {:malformed_text, :session_id, "1"}} = Tmux.observe_panes(server)

      {server, _dir} = fake_tmux!("%|$|test|0|0|1|zsh|/synthetic\n")
      assert {:error, {:malformed_text, :pane_id, "%"}} = Tmux.observe_panes(server)
    end

    test "a text field that is not valid UTF-8 is malformed, not passed through" do
      bad = <<"/synthetic/", 0xFF, "x">>
      {server, _dir} = fake_tmux!("%pane-a|$1|test|0|0|1|zsh|" <> bad <> "\n")

      assert {:error, {:malformed_text, :path, ^bad}} = Tmux.observe_panes(server)
    end
  end

  describe "show_options/3" do
    test "argv is show-options -t <target> -v <option>, output verbatim with its newline" do
      value = ~s({"owner_root":"/synthetic/root","note":"café \ttab 'q'"}\n)
      {server, dir} = fake_tmux!(value)

      assert {:ok, ^value} = Tmux.show_options("$3", @option, server)
      assert argv!(dir) == ["show-options", "-t", "$3", "-v", @option]
      assert calls!(dir) == 1
    end

    test "a non-zero exit is the unclassified error map carrying the argv" do
      {server, _dir} = fake_tmux!("invalid option: #{@option}\n", status: 1, stream: :stderr)

      assert {:error, %{cmd: [_bin | argv], status: 1, stderr: stderr}} =
               Tmux.show_options("$3", @option, server)

      assert argv == ["show-options", "-t", "$3", "-v", @option]
      assert stderr == "invalid option: #{@option}\n"
    end
  end

  describe "set_option/4" do
    test "argv is set-option -t <target> <option> <value> with the value as one element" do
      value = ~s({"generation":"42","name":"with space\tand\ttab \"q\" 'a' é"})
      {server, dir} = fake_tmux!("")

      assert :ok = Tmux.set_option("$3", @option, value, server)
      assert argv!(dir) == ["set-option", "-t", "$3", @option, value]
      assert calls!(dir) == 1
    end

    test "a non-zero exit is the error map" do
      {server, _dir} = fake_tmux!("can't find session: $9\n", status: 1, stream: :stderr)

      assert {:error, %{status: 1, stderr: "can't find session: $9\n"}} =
               Tmux.set_option("$9", @option, "v", server)
    end
  end

  describe "set_option_if_absent/4" do
    test "argv is set-option -o -t <target> <option> <value>" do
      value = ~s({"generation":"7"})
      {server, dir} = fake_tmux!("")

      assert :ok = Tmux.set_option_if_absent("$3", @option, value, server)
      assert argv!(dir) == ["set-option", "-o", "-t", "$3", @option, value]
      assert calls!(dir) == 1
    end

    test "tmux's refusal of an existing option is the typed :option_exists, never :ok" do
      {server, dir} = fake_tmux!("already set: #{@option}\n", status: 1, stream: :stderr)

      result = Tmux.set_option_if_absent("$3", @option, "loser", server)

      refute result == :ok, "a refused conditional write must not be reported as success"
      assert {:error, :option_exists} = result
      assert argv!(dir) == ["set-option", "-o", "-t", "$3", @option, "loser"]
    end

    test "any other failure keeps the error map so a lost race is not confused with it" do
      {server, _dir} = fake_tmux!("can't find session: $9\n", status: 1, stream: :stderr)

      assert {:error, %{status: 1, stderr: "can't find session: $9\n"}} =
               Tmux.set_option_if_absent("$9", @option, "v", server)
    end

    test "the refusal text on a zero exit is still success, because tmux said so" do
      # The mapping keys on the non-zero status AND the message; stdout that
      # merely contains the words is not a refusal.
      {server, _dir} = fake_tmux!("already set: #{@option}\n")

      assert :ok = Tmux.set_option_if_absent("$3", @option, "v", server)
    end
  end
end
