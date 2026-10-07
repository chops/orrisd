defmodule AiPair.TmuxGatedPasteTest do
  @moduledoc """
  NS-15.G.003 S3a: the gated transaction resolves its tmux binary the way the rest of the
  module's callers find it. Port.open/2 with :spawn_executable does not search PATH, so a
  bare configured name ("tmux", the production default) is looked up on PATH; a path is
  used as configured; a binary found nowhere refuses before any marker or tmux step. Every
  step is run by the begin-answering gate itself (T4).
  """

  use ExUnit.Case, async: false

  alias AiPair.Tmux

  setup do
    dir = Path.join(System.tmp_dir!(), "gated-bin-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp stub!(dir, name) do
    path = Path.join(dir, name)
    File.write!(path, "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(path, 0o700)
    path
  end

  test "T1 a bare name is resolved on PATH; a configured path is kept", c do
    name = "ai_pair_gated_stub_#{System.unique_integer([:positive])}"
    path = stub!(c.dir, name)
    old = System.get_env("PATH")
    System.put_env("PATH", c.dir <> ":" <> old)
    on_exit(fn -> System.put_env("PATH", old) end)

    assert Tmux.resolve_executable(name) == {:ok, path}
    assert Tmux.resolve_executable(path) == {:ok, path}
  end

  test "T2 a binary found nowhere refuses before begin: no marker, no step", c do
    missing = "ai_pair_no_such_tmux_#{System.unique_integer([:positive])}"
    assert Tmux.resolve_executable(missing) == {:error, :tmux_not_found}
    assert Tmux.resolve_executable(Path.join(c.dir, "absent")) == {:error, :tmux_not_found}

    name = :"gated_missing_#{System.unique_integer([:positive])}"
    start_supervised!({Tmux, [name: name, tmux_bin: missing]})

    # The store is a process that must never be called: begin is not reached.
    store = spawn(fn -> receive do: (_ -> exit(:called)) end)

    gate = %{
      store: store,
      msg_id: "snd_" <> String.duplicate("0", 64),
      attempt: 1,
      token: make_ref()
    }

    assert {:error, {:gate_refused, :tmux_not_found}} =
             Tmux.gated_paste("%" <> "x", "bytes", gate, name)

    assert Process.alive?(store)
  end

  test "T3 a configured regular file without execute permission refuses before begin", c do
    path = Path.join(c.dir, "not_executable")
    File.write!(path, "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(path, 0o600)

    assert Tmux.resolve_executable(path) == {:error, :tmux_not_found}

    name = :"gated_noexec_#{System.unique_integer([:positive])}"
    start_supervised!({Tmux, [name: name, tmux_bin: path]})
    store = spawn(fn -> receive do: (_ -> exit(:called)) end)

    gate = %{
      store: store,
      msg_id: "snd_" <> String.duplicate("0", 64),
      attempt: 1,
      token: make_ref()
    }

    assert {:error, {:gate_refused, :tmux_not_found}} =
             Tmux.gated_paste("%" <> "x", "bytes", gate, name)

    assert Process.alive?(store), "begin_command was never called"
  end

  # A gate process that answers begin, runs the first `allow` steps itself (as the store
  # does), and then refuses (`:refuse`) or exits without replying (`:exit`), as a store that
  # died or restarted does. The Tmux server never spawns a gated step on its own.
  defp gate_process(allow, after_allow) do
    spawn(fn -> gate_loop(allow, after_allow) end)
  end

  defp gate_loop(allow, after_allow) do
    receive do
      {:"$gen_call", from, {:begin_command, _gate}} ->
        GenServer.reply(from, {:ok, "mk_t4"})
        gate_loop(allow, after_allow)

      {:"$gen_call", from, {:run_step, "mk_t4", exe, args}} when allow > 0 ->
        {_output, status} = System.cmd(exe, args, stderr_to_stdout: true)
        GenServer.reply(from, {:ok, status})
        gate_loop(allow - 1, after_allow)

      {:"$gen_call", from, {:run_step, _marker, _exe, _args}} ->
        if after_allow == :exit, do: exit(:gate_gone)
        GenServer.reply(from, {:error, :unknown_marker})
        gate_loop(0, after_allow)

      {:"$gen_call", from, _other} ->
        GenServer.reply(from, :ok)
        gate_loop(allow, after_allow)
    end
  end

  test "T4 every step is run by the gate; a refused or lost gate runs no further step",
       c do
    for {allow, after_allow, expected} <- [
          {0, :refuse, []},
          {0, :exit, []},
          {1, :refuse, ["set-buffer"]},
          {2, :exit, ["set-buffer", "paste-buffer"]}
        ] do
      log = Path.join(c.dir, "log-#{allow}-#{after_allow}")
      File.write!(log, "")
      bin = Path.join(c.dir, "tmux-#{allow}-#{after_allow}")

      File.write!(bin, """
      #!/usr/bin/env bash
      sub=""; skip=0; for a in "$@"; do if [ "$skip" = 1 ]; then skip=0; continue; fi; case "$a" in -L|-S) skip=1;; -*) ;; *) sub="$a"; break;; esac; done
      printf '%s\\n' "$sub" >> '#{log}'
      exit 0
      """)

      File.chmod!(bin, 0o700)
      name = :"gated_t4_#{System.unique_integer([:positive])}"
      start_supervised!({Tmux, [name: name, tmux_bin: bin]}, id: name)

      gate = %{
        store: gate_process(allow, after_allow),
        msg_id: "snd_" <> String.duplicate("0", 64),
        attempt: 1,
        token: make_ref()
      }

      assert {:error, {:paste_failed, :gate_lost}} =
               Tmux.gated_paste("%" <> "x", "bytes", gate, name)

      # the server's own pane census (list-panes) is not a gated step
      steps =
        log |> File.read!() |> String.split("\n", trim: true) |> Enum.reject(&(&1 == "list-panes"))

      assert steps == expected, inspect({allow, after_allow})
    end
  end
end
