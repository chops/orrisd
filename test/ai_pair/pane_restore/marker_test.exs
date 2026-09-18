defmodule AiPair.PaneRestore.MarkerTest do
  # R04 slice S5: the session marker reader and writer, measured against the
  # contract in docs/contracts/tmux-session-marker.org through a scripted fake
  # `tmux` (AiPair.Test.ScriptedTmux). No tmux server of any kind is started:
  # every tmux answer here is bytes this file scripted, and every claim about
  # what Marker asked tmux is read from the argv the stub recorded.
  use ExUnit.Case, async: true

  alias AiPair.PaneRestore.Marker
  alias AiPair.Test.ScriptedTmux

  @option "@ai_pair_session_incarnation"
  @root "/synthetic/inbox"
  @elsewhere "/synthetic/elsewhere"
  @session "$3"
  @generation "213598703592091008239502170616955211460"
  @show_argv ["show-options", "-t", @session, "-v", @option]
  @generation_format ~r/\A[0-9]+\z/

  # What `show-options -v` prints for an unset user option (tmux 3.7c spelling).
  @absent {"invalid option: #{@option}\n", 1, :stderr}
  # What `set-option -o` prints when the option already exists.
  @option_exists {"already set: #{@option}\n", 1, :stderr}
  # A target tmux cannot address, on either command.
  @no_session {"can't find session: #{@session}\n", 1, :stderr}

  defp marker_json(overrides \\ %{}) do
    %{
      "version" => 1,
      "owner_root" => @root,
      "session_id" => @session,
      "generation" => @generation
    }
    |> Map.merge(overrides)
    |> Jason.encode!()
  end

  # The bytes `show-options -v` prints for a stored value: the value plus one newline.
  defp shown(value), do: {value <> "\n", 0}

  defp set_option_argvs(dir) do
    dir |> ScriptedTmux.argvs!() |> Enum.filter(&(hd(&1) == "set-option"))
  end

  defp ensure(server, opts \\ []) do
    Marker.ensure(
      server,
      @session,
      Keyword.merge([owner_root: @root, generation: @generation], opts)
    )
  end

  describe "read/2" do
    test "argv is show-options -t <session_id> -v <option>, one call, and the marker decodes" do
      {server, dir} = ScriptedTmux.start!([shown(marker_json())])

      assert {:ok, marker} = Marker.read(server, @session)

      assert marker == %{
               version: 1,
               owner_root: @root,
               session_id: @session,
               generation: @generation
             }

      assert ScriptedTmux.argv!(dir, 1) == @show_argv
      assert ScriptedTmux.calls!(dir) == 1
    end

    test "adds nothing of its own to the adapter's invocation (socket flag comes from the adapter)" do
      {server, dir} = ScriptedTmux.start!([shown(marker_json())], socket_name: "marker_sock")

      assert {:ok, _} = Marker.read(server, @session)
      assert ScriptedTmux.argv!(dir, 1) == ["-L", "marker_sock" | @show_argv]
    end

    test "an unset option is {:marker_absent}, under either tmux spelling" do
      {server, _dir} = ScriptedTmux.start!([@absent])
      assert {:error, {:marker_absent}} = Marker.read(server, @session)

      {server, _dir} = ScriptedTmux.start!([{"unknown option: #{@option}\n", 1, :stderr}])
      assert {:error, {:marker_absent}} = Marker.read(server, @session)
    end

    test "any other show-options failure is {:source_error, :marker, map}, never absence" do
      {server, _dir} = ScriptedTmux.start!([@no_session])

      result = Marker.read(server, @session)

      refute match?({:error, {:marker_absent}}, result),
             "an unaddressable session must not be reported as a session with no marker"

      assert {:error, {:source_error, :marker, %{cmd: [_bin | argv], status: 1, stderr: stderr}}} =
               result

      assert argv == @show_argv
      assert stderr == "can't find session: #{@session}\n"
    end

    test "an adapter that cannot be asked is {:source_unavailable, :marker}, not absence" do
      result = Marker.read(:marker_test_no_such_adapter, @session)

      refute match?({:error, {:marker_absent}}, result)
      assert {:error, {:source_unavailable, :marker}} = result
    end

    test "the stored session_id is reported verbatim, not checked against the target" do
      {server, _dir} = ScriptedTmux.start!([shown(marker_json(%{"session_id" => "$9"}))])

      assert {:ok, %{session_id: "$9"}} = Marker.read(server, @session)
    end

    test "trailing newlines are stripped before decoding and raw carries the trimmed value" do
      {server, _dir} = ScriptedTmux.start!([{"not a marker\n", 0}])
      assert {:error, {:marker_malformed, "not a marker"}} = Marker.read(server, @session)

      {server, _dir} = ScriptedTmux.start!([{marker_json() <> "\n\n", 0}])
      assert {:ok, %{generation: @generation}} = Marker.read(server, @session)
    end

    test "member order and whitespace are not compared: only the parsed object is" do
      reordered =
        ~s({ "session_id" : "#{@session}", "generation" : "7",\n "version" : 1, "owner_root" : "#{@root}" })

      {server, _dir} = ScriptedTmux.start!([shown(reordered)])

      assert {:ok, %{version: 1, owner_root: @root, session_id: @session, generation: "7"}} =
               Marker.read(server, @session)
    end

    test "any non-empty digit string is a generation" do
      long = String.duplicate("9", 60)
      {server, _dir} = ScriptedTmux.start!([shown(marker_json(%{"generation" => long}))])

      assert {:ok, %{generation: ^long}} = Marker.read(server, @session)
    end
  end

  describe "read/2 malformed values" do
    # Each row is `{label, bytes}`; every one must be `{:marker_malformed, bytes}`
    # with the trimmed value as `raw`, never `{:ok, _}` and never absence. Built
    # from module-body bindings because the rows are unrolled at compile time.
    base = %{
      "version" => 1,
      "owner_root" => @root,
      "session_id" => @session,
      "generation" => @generation
    }

    valid = Jason.encode!(base)
    with_member = fn key, value -> Jason.encode!(Map.put(base, key, value)) end

    malformed = [
      {"not JSON", "not a marker"},
      {"empty value", ""},
      {"a bare string", ~s("#{@root}")},
      {"an array wrapping the object", "[" <> valid <> "]"},
      {"version as a string", with_member.("version", "1")},
      {"version as a float",
       ~s({"version":1.0,"owner_root":"#{@root}","session_id":"#{@session}","generation":"1"})},
      {"version 2", with_member.("version", 2)},
      {"a missing member", Jason.encode!(Map.delete(base, "generation"))},
      {"an extra member", with_member.("extra", "unexpected")},
      {"a relative owner_root", with_member.("owner_root", "synthetic/inbox")},
      {"an empty owner_root", with_member.("owner_root", "")},
      {"an empty session_id", with_member.("session_id", "")},
      {"a non-string session_id", with_member.("session_id", 3)},
      {"a generation with a letter", with_member.("generation", "12a")},
      {"an empty generation", with_member.("generation", "")},
      {"a negative generation", with_member.("generation", "-1")},
      {"a numeric generation", with_member.("generation", 7)},
      {"a top-level duplicate key with differing values",
       ~s({"version":1,"owner_root":"#{@root}","session_id":"#{@session}","generation":"1","generation":"2"})},
      {"a top-level duplicate key with identical values (last-value-wins would pass)",
       ~s({"version":1,"owner_root":"#{@root}","session_id":"#{@session}","generation":"1","generation":"1"})},
      {"a duplicate owner_root",
       ~s({"version":1,"owner_root":"#{@root}","owner_root":"/elsewhere","session_id":"#{@session}","generation":"1"})},
      {"a duplicate key nested in an object member",
       ~s({"version":1,"owner_root":"#{@root}","session_id":"#{@session}","generation":{"k":1,"k":2}})},
      {"a duplicate key nested inside an array",
       ~s([{"version":1,"owner_root":"#{@root}","session_id":"#{@session}","generation":"1","x":[{"k":1,"k":2}]}])},
      {"a duplicate key nested two objects deep",
       ~s({"version":1,"owner_root":"#{@root}","session_id":"#{@session}","generation":"1","x":{"y":{"k":1,"k":2}}})},
      {"an owner_root that is not UTF-8",
       ~s({"version":1,"owner_root":"/synthetic/) <>
         <<0xFF>> <> ~s(","session_id":"#{@session}","generation":"1"})}
    ]

    for {label, bytes} <- malformed do
      test "#{label} is {:marker_malformed, raw}" do
        bytes = unquote(bytes)
        {server, _dir} = ScriptedTmux.start!([{bytes <> "\n", 0}])

        result = Marker.read(server, @session)

        refute match?({:ok, _}, result), "must not be usable: #{inspect(bytes)}"
        refute match?({:error, {:marker_absent}}, result), "must not be absence: #{inspect(bytes)}"
        assert {:error, {:marker_malformed, ^bytes}} = result
      end
    end
  end

  describe "ensure/3 on an absent marker" do
    test "is read, one set-option -o with the four-member JSON, then a read-back; :ok on a same-owner winner" do
      {server, dir} = ScriptedTmux.start!([@absent, {"", 0}, shown(marker_json())])

      assert :ok = ensure(server)

      assert ScriptedTmux.calls!(dir) == 3
      assert ScriptedTmux.argv!(dir, 1) == @show_argv
      assert ["set-option", "-o", "-t", @session, @option, value] = ScriptedTmux.argv!(dir, 2)
      assert ScriptedTmux.argv!(dir, 3) == @show_argv

      # Exactly the contract's four members, no whitespace, no newline.
      assert Jason.decode!(value) == %{
               "version" => 1,
               "owner_root" => @root,
               "session_id" => @session,
               "generation" => @generation
             }

      refute String.contains?(value, ["\n", " "])
    end

    test "the read-back decides: a write reported as success is not evidence of what tmux stored" do
      # Success, then nothing there: the contract's {:marker_absent}.
      {server, _dir} = ScriptedTmux.start!([@absent, {"", 0}, @absent])
      assert {:error, {:marker_absent}} = ensure(server)

      # Success, then a foreign winner.
      {server, _dir} =
        ScriptedTmux.start!([@absent, {"", 0}, shown(marker_json(%{"owner_root" => @elsewhere}))])

      assert {:error, {:marker_foreign, @elsewhere}} = ensure(server)

      # Success, then an unusable value.
      {server, _dir} = ScriptedTmux.start!([@absent, {"", 0}, {"not a marker\n", 0}])
      assert {:error, {:marker_malformed, "not a marker"}} = ensure(server)

      # Success, then the read-back itself fails.
      {server, _dir} = ScriptedTmux.start!([@absent, {"", 0}, @no_session])
      assert {:error, {:source_error, :marker, %{status: 1}}} = ensure(server)
    end

    test "the loser of a race adopts the winner's generation: :ok, and read/2 reports the winner" do
      winner = "7"
      readback = shown(marker_json(%{"generation" => winner}))
      {server, dir} = ScriptedTmux.start!([@absent, @option_exists, readback, readback])

      assert :ok = ensure(server, generation: "42")
      assert {:ok, %{generation: ^winner}} = Marker.read(server, @session)

      [set_argv] = set_option_argvs(dir)
      assert "-o" in set_argv, "the attempt must be set-if-absent: #{inspect(set_argv)}"
      assert Jason.decode!(List.last(set_argv))["generation"] == "42"
    end

    test "a failed write followed by an absent read-back is {:source_error, :marker, error}" do
      {server, _dir} = ScriptedTmux.start!([@absent, @no_session, @absent])

      assert {:error, {:source_error, :marker, %{cmd: [_bin | argv], status: 1, stderr: stderr}}} =
               ensure(server)

      assert ["set-option", "-o", "-t", @session, @option, _value] = argv
      assert stderr == "can't find session: #{@session}\n"
    end
  end

  describe "ensure/3 when the conditional write answers {:error, :option_exists}" do
    test "a same-owner winner with another generation is :ok" do
      {server, dir} =
        ScriptedTmux.start!([@absent, @option_exists, shown(marker_json(%{"generation" => "1"}))])

      assert :ok = ensure(server)
      assert ScriptedTmux.calls!(dir) == 3
      assert length(set_option_argvs(dir)) == 1
    end

    test "a foreign winner is {:marker_foreign, owner}, and the option is not written again" do
      {server, dir} =
        ScriptedTmux.start!([
          @absent,
          @option_exists,
          shown(marker_json(%{"owner_root" => @elsewhere, "generation" => "1"}))
        ])

      assert {:error, {:marker_foreign, @elsewhere}} = ensure(server)
      assert ScriptedTmux.calls!(dir) == 3
      assert length(set_option_argvs(dir)) == 1
    end

    test "an unparsable winner is {:marker_malformed, raw}" do
      {server, dir} = ScriptedTmux.start!([@absent, @option_exists, {"not a marker\n", 0}])

      assert {:error, {:marker_malformed, "not a marker"}} = ensure(server)
      assert ScriptedTmux.calls!(dir) == 3
    end

    test "a winner removed again before the read-back is {:source_error, :marker, :option_exists}" do
      # The option existed at write time and was gone at read time: neither a
      # claim nor a stable absence. The write's typed answer names the case.
      {server, dir} = ScriptedTmux.start!([@absent, @option_exists, @absent])

      result = ensure(server)

      refute result == :ok
      refute match?({:error, {:marker_absent}}, result)
      assert {:error, {:source_error, :marker, :option_exists}} = result
      assert ScriptedTmux.calls!(dir) == 3
    end

    test "a read-back that fails outright is that failure" do
      {server, _dir} = ScriptedTmux.start!([@absent, @option_exists, @no_session])

      assert {:error, {:source_error, :marker, %{status: 1, cmd: [_bin | @show_argv]}}} =
               ensure(server)
    end
  end

  describe "ensure/3 never overwrites" do
    test "a present same-owner marker is :ok with zero writes, whatever its generation" do
      {server, dir} = ScriptedTmux.start!([shown(marker_json(%{"generation" => "1"}))])

      assert :ok = ensure(server, generation: "2")
      assert ScriptedTmux.calls!(dir) == 1
      assert set_option_argvs(dir) == []
    end

    test "a present foreign marker is {:marker_foreign, owner} with zero writes" do
      {server, dir} = ScriptedTmux.start!([shown(marker_json(%{"owner_root" => @elsewhere}))])

      assert {:error, {:marker_foreign, @elsewhere}} = ensure(server)
      assert ScriptedTmux.calls!(dir) == 1
      assert set_option_argvs(dir) == []
    end

    test "a malformed marker is {:marker_malformed, raw} with zero writes: never repaired" do
      raw = marker_json(%{"version" => 2})
      {server, dir} = ScriptedTmux.start!([shown(raw)])

      assert {:error, {:marker_malformed, ^raw}} = ensure(server)
      assert ScriptedTmux.calls!(dir) == 1
      assert set_option_argvs(dir) == []
    end

    test "a failed read is returned unchanged with zero writes: never treated as absence" do
      {server, dir} = ScriptedTmux.start!([@no_session])

      assert {:error, {:source_error, :marker, %{status: 1}}} = ensure(server)
      assert ScriptedTmux.calls!(dir) == 1
      assert set_option_argvs(dir) == []
    end

    test "an adapter that cannot be asked is {:source_unavailable, :marker}" do
      assert {:error, {:source_unavailable, :marker}} =
               Marker.ensure(:marker_test_no_such_adapter, @session,
                 owner_root: @root,
                 generation: @generation
               )
    end

    test "a second ensure with a different generation issues no write at all, conditional or plain" do
      first = marker_json(%{"generation" => "1"})

      {server, dir} =
        ScriptedTmux.start!([@absent, {"", 0}, shown(first), shown(first), shown(first)])

      assert :ok = ensure(server, generation: "1")
      assert :ok = ensure(server, generation: "2")
      assert {:ok, %{generation: "1"}} = Marker.read(server, @session)

      assert ScriptedTmux.calls!(dir) == 5
      assert [set_argv] = set_option_argvs(dir)
      assert Enum.take(set_argv, 2) == ["set-option", "-o"]
      assert Jason.decode!(List.last(set_argv))["generation"] == "1"

      refute Enum.any?(ScriptedTmux.argvs!(dir), &match?(["set-option", "-t" | _], &1)),
             "a plain set-option was issued: #{inspect(ScriptedTmux.argvs!(dir))}"
    end

    test "a bad caller value raises rather than reaching tmux" do
      {server, dir} = ScriptedTmux.start!([])

      assert_raise ArgumentError, fn ->
        Marker.ensure(server, @session, owner_root: "relative/root", generation: "1")
      end

      assert_raise ArgumentError, fn ->
        Marker.ensure(server, @session, owner_root: @root, generation: "12a")
      end

      assert_raise KeyError, fn -> Marker.ensure(server, @session, owner_root: @root) end
      assert ScriptedTmux.calls!(dir) == 0
    end
  end

  describe "mint_generation/0" do
    test "is a decimal string of 1 to 39 digits below 2^128, and does not repeat" do
      mints = for _ <- 1..200, do: Marker.mint_generation()

      for g <- mints do
        assert Regex.match?(@generation_format, g), "not decimal: #{inspect(g)}"
        assert String.length(g) in 1..39
        assert String.to_integer(g) < Integer.pow(2, 128)
      end

      assert length(Enum.uniq(mints)) == 200
    end
  end
end
