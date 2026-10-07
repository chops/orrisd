defmodule AiPair.Test.GatedTmuxStub do
  @moduledoc """
  A REAL `AiPair.Tmux` adapter over a Bash stub `tmux`, for the gated transaction
  (NS-32.M.002 RB-3a GREEN-2 F-1). The stub answers every subcommand with exit 0 and records its
  argv; while the row has created `park`, its `paste-buffer` step writes `at_paste` and waits for
  `release` to exist before exiting 0, so the transaction can be held inside its mutation.

  The adapter is started unlinked (it outlives the application restarts a row performs) and
  stopped by the row's `on_exit`.
  """

  def start! do
    dir = Path.join(System.tmp_dir!(), "gated_tmux_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    bin = Path.join(dir, "tmux")

    File.write!(bin, """
    #!/usr/bin/env bash
    here='#{dir}'
    printf '%s\\n' "$*" >> "$here/argv.log" || exit 90
    cmd=""
    for arg in "$@"; do
      case "$arg" in
        -*) ;;
        *) cmd="$arg"; break ;;
      esac
    done
    if [ "$cmd" = paste-buffer ] && [ -e "$here/park" ]; then
      : > "$here/at_paste"
      while [ ! -e "$here/release" ]; do sleep 0.02; done
    fi
    exit 0
    """)

    File.chmod!(bin, 0o700)
    name = String.to_atom("gated_tmux_#{System.unique_integer([:positive])}")
    {:ok, pid} = GenServer.start(AiPair.Tmux, [tmux_bin: bin], name: name)

    ExUnit.Callbacks.on_exit(fn ->
      File.write!(Path.join(dir, "release"), "")
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(dir)
    end)

    %{name: name, dir: dir}
  end

  def park(stub), do: File.write!(Path.join(stub.dir, "park"), "")
  def parked?(stub), do: File.exists?(Path.join(stub.dir, "at_paste"))
  def release(stub), do: File.write!(Path.join(stub.dir, "release"), "")
end
