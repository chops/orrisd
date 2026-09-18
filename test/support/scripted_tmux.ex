defmodule AiPair.Test.ScriptedTmux do
  @moduledoc """
  An owned fake `tmux` for driving `AiPair.Tmux` without any tmux server.

  In the style of `AiPair.TmuxCensusTest`: the adapter is started against a
  Bash stub that records every invocation's argv (NUL separated, one file per
  invocation) and answers each invocation from a script. The script is a list
  of `{output, status}` or `{output, status, stream}` steps, one per invocation
  in order; `output` is printed byte for byte on `stream` (`:stdout` by default,
  `:stderr` when tmux would have complained) and the stub exits with `status`.

  An invocation past the end of the script is the loud failure `exit 99` with
  an `unscripted fake tmux call` message: a test that issues more tmux commands
  than it scripted fails on that status rather than on a silent success.
  """

  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]

  alias AiPair.Tmux

  @type step :: {binary(), non_neg_integer()} | {binary(), non_neg_integer(), :stdout | :stderr}

  @doc "Starts an adapter over a scripted stub; returns `{server, dir}`."
  @spec start!([step()], keyword()) :: {atom(), Path.t()}
  def start!(steps, opts \\ []) when is_list(steps) do
    socket_name = Keyword.get(opts, :socket_name)

    dir = Path.join(System.tmp_dir!(), "scripted_tmux_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "calls"), "0")

    steps
    |> Enum.with_index(1)
    |> Enum.each(fn {step, n} -> write_step!(dir, n, step) end)

    bin = Path.join(dir, "tmux")

    File.write!(bin, """
    #!/bin/bash
    here=$(cd "$(dirname "$0")" && pwd -P)
    n=$(<"$here/calls")
    n=$((n + 1))
    printf '%s' "$n" >"$here/calls"
    printf '%s\\0' "$@" >"$here/argv.$n"
    if [ ! -f "$here/status.$n" ]; then
      printf 'unscripted fake tmux call %s\\n' "$n" >&2
      exit 99
    fi
    if [ "$(<"$here/stream.$n")" = stderr ]; then
      cat "$here/out.$n" >&2
    else
      cat "$here/out.$n"
    fi
    exit "$(<"$here/status.$n")"
    """)

    File.chmod!(bin, 0o700)

    name = String.to_atom("scripted_tmux_#{System.unique_integer([:positive])}")
    opts = [name: name, tmux_bin: bin, socket_name: socket_name]
    start_supervised!(Supervisor.child_spec({Tmux, opts}, id: name))
    {name, dir}
  end

  @doc "The argv of invocation `n` (1-based), as a list of strings."
  @spec argv!(Path.t(), pos_integer()) :: [String.t()]
  def argv!(dir, n) do
    dir
    |> Path.join("argv.#{n}")
    |> File.read!()
    |> :binary.split(<<0>>, [:global])
    |> List.delete_at(-1)
  end

  @doc "Every recorded argv, in invocation order."
  @spec argvs!(Path.t()) :: [[String.t()]]
  def argvs!(dir), do: for(n <- 1..calls!(dir)//1, do: argv!(dir, n))

  @doc "How many invocations the stub has answered."
  @spec calls!(Path.t()) :: non_neg_integer()
  def calls!(dir), do: dir |> Path.join("calls") |> File.read!() |> String.to_integer()

  defp write_step!(dir, n, {output, status}), do: write_step!(dir, n, {output, status, :stdout})

  defp write_step!(dir, n, {output, status, stream})
       when is_binary(output) and is_integer(status) and stream in [:stdout, :stderr] do
    File.write!(Path.join(dir, "out.#{n}"), output)
    File.write!(Path.join(dir, "status.#{n}"), Integer.to_string(status))
    File.write!(Path.join(dir, "stream.#{n}"), Atom.to_string(stream))
  end
end
