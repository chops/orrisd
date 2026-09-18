defmodule AiPair.RouteContainmentControlTest do
  @moduledoc """
  The control that fails when test-capture containment regresses.

  The defect this closes: a suite that drives the PRODUCT default pane path
  executes `tmux` against the operator's own server. The chain is
  `IPC.Server.attach_pane/3` (`ipc/server.ex:387-391`, no `:capture_fn`) ->
  `PaneSupervisor.start_pane/2` (`pane_supervisor.ex:37-57`, opts forwarded
  verbatim) -> `StateMachine` defaults (`state_machine.ex:246-247`,
  `default_capture/1` at `:847-849`, addressing the registered `AiPair.Tmux`)
  -> the adapter started with `[]` (`application.ex:32`) -> no `-L`
  (`prepend_socket/2`, `tmux.ex:571-572`) -> `System.cmd`
  (`run_tmux/2`, `tmux.ex:543`).

  `AiPair.Test.RouteGuard.install!/1` closes that route by holding the
  registered name. Installing it is therefore a property of the SOURCE of the
  driving suites, and this file asserts that property so that deleting an
  `install!` fails here instead of silently reopening the escape.
  """

  use ExUnit.Case, async: true

  # The suites measured (receipts `measure-full.route-calls.log`) to drive the
  # product default pane path. `boot_wiring_test.exs` is the suite that first
  # measured the boundary; `server_test.exs` and `client_test.exs` are the two
  # that were escaping.
  @measured_driving_suites [
    "test/ai_pair/cli/client_test.exs",
    "test/ai_pair/ipc/server_test.exs",
    "test/ai_pair/pane_restore/boot_wiring_test.exs"
  ]

  # A file that mentions RouteGuard ONLY in prose. It is the refutation control
  # for `installs_guard?/1`: a detector that matched text rather than a call
  # would report this file as guarded, and this suite would then pass while
  # asserting nothing.
  @prose_only_mention "test/ai_pair/pane_restore/quarantine_test.exs"

  describe "default-route containment" do
    test "every suite that can drive the product default pane path installs the route guard" do
      driving = Enum.filter(test_files(), &drives_default_route?/1)

      # ANTI-VACUITY. A detector that matched nothing would make the assertion
      # below trivially true, so the three suites the measurement named must be
      # rediscovered from source before the subset claim is allowed to stand.
      for suite <- @measured_driving_suites do
        assert suite in driving,
               "#{suite} drives the product default pane path but the detector " <>
                 "no longer recognises it; the detector, not the suite, is wrong. " <>
                 "Discovered: #{inspect(driving)}"
      end

      unguarded = Enum.reject(driving, &installs_guard?/1)

      assert unguarded == [],
             "these suites can route a pane capture at the OPERATOR's default tmux " <>
               "server and do not install AiPair.Test.RouteGuard: #{inspect(unguarded)}"
    end

    test "each detector rule is live on its own" do
      # Rule 1 must be able to fire: a literal-options `start_pane` without
      # `:capture_fn` is the product default path started directly.
      assert "test/ai_pair/pane_restore/boot_wiring_test.exs" in Enum.filter(
               test_files(),
               &default_routed_start_pane?/1
             )

      # Rule 2 must be able to fire: an `attach_pane` frame sent to a real IPC
      # server is the product default path started through the daemon.
      attach_driving = Enum.filter(test_files(), &drives_ipc_attach?/1)

      assert "test/ai_pair/ipc/server_test.exs" in attach_driving
      assert "test/ai_pair/cli/client_test.exs" in attach_driving

      # ... and must not fire on a file that only ENCODES an attach payload and
      # never starts a server, or the rule would demand a guard where no route
      # exists.
      refute "test/ai_pair/cli/client_attach_payload_test.exs" in attach_driving
    end

    test "installs_guard?/1 reads calls, not prose" do
      refute installs_guard?(@prose_only_mention),
             "#{@prose_only_mention} only MENTIONS RouteGuard in comments; a detector " <>
               "that accepts that would accept a commented-out install! as containment"

      assert installs_guard?("test/ai_pair/ipc/server_test.exs")
    end
  end

  # ===== detectors (AST, never text) =====

  defp test_files do
    "test/**/*_test.exs" |> Path.wildcard() |> Enum.sort()
  end

  defp ast!(file), do: file |> File.read!() |> Code.string_to_quoted!()

  defp drives_default_route?(file) do
    default_routed_start_pane?(file) or drives_ipc_attach?(file)
  end

  # A qualified `X.start_pane(pane, opts)` whose options are a LITERAL list
  # carrying no `:capture_fn`. Deliberately an under-approximation: options
  # built by a helper (`start_pane(id, inert_opts())`) are not judged here,
  # because guessing at a helper's contents would report suites that are
  # already contained by injection. Under-approximating can miss a new escape;
  # over-approximating would make the control unusable and it would be deleted.
  defp default_routed_start_pane?(file) do
    file
    |> ast!()
    |> Macro.prewalk(false, fn
      {{:., _, [_receiver, :start_pane]}, _, [_pane, opts]} = node, acc when is_list(opts) ->
        {node, acc or not Enum.any?(opts, &match?({:capture_fn, _}, &1))}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  # An `attach_pane` command string together with a qualified `start_link/1`
  # call: the file both names the command and starts something that can serve
  # it. `client_attach_payload_test.exs` names the command and starts nothing,
  # and is excluded by the second half.
  defp drives_ipc_attach?(file) do
    ast = ast!(file)
    names_attach_command?(ast) and starts_a_server?(ast)
  end

  defp names_attach_command?(ast) do
    ast
    |> Macro.prewalk(false, fn
      node, acc when is_binary(node) -> {node, acc or String.contains?(node, "attach_pane")}
      node, acc -> {node, acc}
    end)
    |> elem(1)
  end

  defp starts_a_server?(ast) do
    ast
    |> Macro.prewalk(false, fn
      {{:., _, [_receiver, :start_link]}, _, [_opts]} = node, _acc -> {node, true}
      node, acc -> {node, acc}
    end)
    |> elem(1)
  end

  defp installs_guard?(file) do
    file
    |> ast!()
    |> Macro.prewalk(false, fn
      {{:., _, [{:__aliases__, _, parts}, :install!]}, _, _} = node, acc ->
        {node, acc or List.last(parts) == :RouteGuard}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end
end
