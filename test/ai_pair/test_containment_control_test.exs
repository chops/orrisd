defmodule AiPair.TestContainmentControlTest do
  @moduledoc """
  The controls that fail when the suite's own containment posture regresses.

  `AiPair.RouteContainmentControlTest` guards the pane-capture route at the
  OPERATOR's default tmux server. This file guards the two properties that
  bound what the suite STARTS and what it SCANS on the way to that posture.
  Both are properties of test source, so both are asserted from source:

    1. how many LIVE tmux servers a full run starts, and from how many places.
       A server built in `setup` costs one server per row and the cost is
       invisible in review; a server built in `setup_all` costs one per module
       whatever the row count. Neither the set of suites that may start one nor
       the number of places they start one from may change without changing
       this file;
    2. that the suite which censuses every descriptor the BEAM holds runs in
       the serial phase. Its parser refuses any record it cannot frame - which
       is right - so under `async: true` another suite's transient socket can
       abort a census that was never about that socket.

  Both detectors read the AST. The tmux one matches `"new-session"` as an
  ELEMENT of a list - an argv - and never as text, because a suite that only
  describes a tmux server in prose starts nothing. `@prose_only_mention` is the
  refutation control for exactly that, and it is a real file whose moduledoc
  names the command.
  """

  use ExUnit.Case, async: true

  # Measured with a PATH-shadowing `tmux` that logged argv and exec'd the real
  # binary: a full run issued 32 tmux invocations, 8 of them `new-session`, all
  # 8 from this one file, every one of them carrying `-L`.
  @live_server_suites ["test/ai_pair/tmux_test.exs"]

  # The one argv that starts a server, and the two places that reach it: the
  # module's shared `setup_all`, and the per-row `setup` branch for the row
  # whose server must be created under a UTF-8 locale.
  @expected_start_argv_sites 1
  @expected_start_call_sites 2

  @census_suite "test/ai_pair/pane_intent_store_test.exs"

  # A file that names `new-session` ONLY in prose: its moduledoc explains why a
  # carried row was not portable. A detector that matched text rather than an
  # argv element would report it as starting a server, and the pinned-set
  # assertion would then be asserting the detector's bug.
  @prose_only_mention "test/ai_pair/pane_restore/application_durable_boot_test.exs"

  describe "live tmux servers" do
    test "only the pinned suites start one" do
      starting = Enum.filter(test_files(), &starts_tmux_server?/1)

      assert Enum.sort(starting) == Enum.sort(@live_server_suites),
             "a suite that starts a live tmux server must be listed here deliberately. " <>
               "Discovered: #{inspect(starting)}"
    end

    test "the count cannot grow without this file changing" do
      # ANTI-VACUITY: the detector must still find the one file that does start
      # servers, or every assertion below is about an empty file set.
      assert starts_tmux_server?("test/ai_pair/tmux_test.exs")

      suite = "test/ai_pair/tmux_test.exs"

      assert start_argv_sites(suite) == @expected_start_argv_sites,
             "servers must come from ONE argv that review can see in one place"

      assert start_call_sites(suite) == @expected_start_call_sites,
             "the number of places that start a live tmux server changed; a third " <>
               "server is a decision, not an incidental cost"

      assert start_calls_in_setup_all(suite) == 1,
             "the shared server must be created once per MODULE, in setup_all; a start " <>
               "moved into an unconditional setup costs one server per row again"
    end

    test "the detector reads argv, not prose" do
      assert @prose_only_mention in test_files(),
             "the refutation control must name a file the walker really reads"

      refute starts_tmux_server?(@prose_only_mention),
             "#{@prose_only_mention} only NAMES new-session in its moduledoc; a detector " <>
               "that accepted that would accept a comment as a running server"
    end
  end

  describe "the whole-BEAM descriptor census" do
    test "its suite runs in the serial phase" do
      refute async?(@census_suite),
             "#{@census_suite} censuses every descriptor the BEAM holds and refuses any " <>
               "record it cannot frame; under async: true another suite's transient " <>
               "socket aborts a census that was never about it"
    end

    test "the census really is whole-BEAM, so the rule above is not guarding a stale fact" do
      # If the scan is ever narrowed to the target, this fails and the serial
      # requirement should be re-derived rather than carried forward unexamined.
      assert @census_suite |> File.read!() |> String.contains?(~s(["-F", "pfn", "-p")),
             "the census scope changed; re-derive whether the serial phase is still owed"
    end

    test "async?/1 can report both answers" do
      # A detector stuck on one answer would make the rule above vacuous.
      assert async?("test/ai_pair/tmux_census_test.exs")
      refute async?(@prose_only_mention)
    end
  end

  # ===== detectors (AST, never text) =====

  defp test_files do
    "test/**/*_test.exs" |> Path.wildcard() |> Enum.sort()
  end

  defp ast!(file), do: file |> File.read!() |> Code.string_to_quoted!()

  defp starts_tmux_server?(file), do: start_argv_sites(file) > 0

  # `"new-session"` as an ELEMENT of a list literal: that list is the argv of
  # the `System.cmd` that starts a server. Prose mentioning the command is a
  # string that CONTAINS the word, never a string that IS it.
  defp start_argv_sites(file), do: file |> ast!() |> count_start_argv()

  defp count_start_argv(ast) do
    ast
    |> Macro.prewalk(0, fn
      node, acc when is_list(node) -> {node, acc + if("new-session" in node, do: 1, else: 0)}
      node, acc -> {node, acc}
    end)
    |> elem(1)
  end

  # Calls to the module's own server starter. The `defp` clause head is itself
  # a matching node, so the definitions are counted separately and subtracted;
  # what remains is call sites.
  defp start_call_sites(file) do
    ast = ast!(file)
    count(ast, &start_server_node?/1) - count(ast, &start_server_definition?/1)
  end

  defp start_calls_in_setup_all(file) do
    file
    |> ast!()
    |> Macro.prewalk(0, fn
      {:setup_all, _, _} = node, acc -> {node, acc + count(node, &start_server_node?/1)}
      node, acc -> {node, acc}
    end)
    |> elem(1)
  end

  defp start_server_node?({:start_server!, _, args}) when is_list(args), do: true
  defp start_server_node?(_), do: false

  defp start_server_definition?({:defp, _, [{:start_server!, _, _} | _]}), do: true
  defp start_server_definition?(_), do: false

  defp count(ast, predicate) do
    ast
    |> Macro.prewalk(0, fn node, acc ->
      {node, acc + if(predicate.(node), do: 1, else: 0)}
    end)
    |> elem(1)
  end

  defp async?(file) do
    file
    |> ast!()
    |> Macro.prewalk(false, fn
      {:use, _, [{:__aliases__, _, [:ExUnit, :Case]}, opts]} = node, acc when is_list(opts) ->
        {node, acc or Keyword.get(opts, :async) == true}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end
end
