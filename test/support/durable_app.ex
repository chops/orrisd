defmodule AiPair.Test.DurableApp do
  @moduledoc """
  Boots the ACTUAL `:ai_pair` application in durable mode under a fixture inbox, for the
  NS-32.M.002 RB-3a GREEN-2 rows (design r4 W1/W5), and restores the suite's own application
  afterwards. The pattern and its containment are `AiPair.ApplicationDurableBootTest`'s:

    * a refusing Bash `tmux` is first on PATH for the whole boot, so the application's own
      `AiPair.Tmux` child can reach nothing real (list-panes empty, show-options absent, every
      other subcommand refused, exit 97);
    * `:tmux_server` names an `AiPair.Test.FakeTmuxAdapter` the row controls (census, session
      markers), so Boot, durable attach and the quiesce observation read the row's panes;
    * stop is proved (the supervisor's DOWN is joined) before PATH and the keys are restored.

  Rows using this cannot install `AiPair.Test.RouteGuard` (the guard holds the `AiPair.Tmux`
  name the application's own child needs); the PATH boundary above is their containment.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @keys [
    :durable_attachments,
    :project_binding,
    :tmux_server,
    :boot_generation,
    :pane_intent_store_fs,
    :pane_intent_store_module,
    :quiesce_bound_ms
  ]
  @vars ["AI_PAIR_INBOX", "PATH"]
  @inbox_subdirs ~w(sock fingerprints logs state inbox outbox processed)

  @doc "Boot durable with `rows` in the fake adapter; returns the fixture map."
  def boot!(rows, extra_env \\ []) do
    inbox = inbox_root!()
    wrapper = refusing_tmux_on_path!()
    tmux = AiPair.Test.FakeTmuxAdapter.start!(rows)
    prior_vars = Map.new(@vars, &{&1, System.get_env(&1)})
    prior_keys = Map.new(@keys, &{&1, Application.fetch_env(:ai_pair, &1)})

    on_exit(fn ->
      stop_app!()
      File.write!(Path.join(wrapper, "CONTAINED"), "stop joined\n")
      restore_vars!(prior_vars)
      restore_keys!(prior_keys)
      {:ok, _} = Application.ensure_all_started(:ai_pair)
    end)

    stop_app!()
    System.put_env("AI_PAIR_INBOX", inbox)
    System.put_env("PATH", wrapper <> ":" <> (prior_vars["PATH"] || ""))
    Enum.each(@keys, &Application.delete_env(:ai_pair, &1))
    Application.put_env(:ai_pair, :durable_attachments, true)
    Application.put_env(:ai_pair, :project_binding, binding_for(inbox))
    Application.put_env(:ai_pair, :tmux_server, tmux)
    Enum.each(extra_env, fn {key, value} -> Application.put_env(:ai_pair, key, value) end)

    {:ok, _} = Application.ensure_all_started(:ai_pair)
    supervisor = Process.whereis(AiPair.Supervisor)

    %{
      inbox: inbox,
      sock: Path.join([inbox, "sock", "ai-pair.sock"]),
      tmux: tmux,
      supervisor: supervisor,
      receipt_store: {:global, {AiPair.Delivery.ReceiptStore, Path.expand(inbox)}},
      intent_store: {:global, {AiPair.PaneIntentStore, Path.expand(inbox)}}
    }
  end

  @doc """
  Stop the fixture daemon (proved) and start it again on the same inbox, environment and
  adapter: a daemon restart, so Boot reconciles what the previous daemon committed.
  """
  def restart!(app) do
    stop_app!()
    {:ok, _} = Application.ensure_all_started(:ai_pair)
    %{app | supervisor: Process.whereis(AiPair.Supervisor)}
  end

  @doc "A census row for `pane` in `session` (the fields `AiPair.Tmux.observe_panes/1` gives)."
  def row(pane, session, root, pid) do
    %{
      pane_id: pane,
      session_id: session,
      session_name: "fixture" <> String.trim_leading(session, "$"),
      window_index: 0,
      pane_index: 0,
      pane_pid: pid,
      command: "bash",
      path: root
    }
  end

  @doc "One request frame over the daemon socket; the decoded reply."
  def request(sock, payload, timeout \\ 10_000) do
    {:ok, client} =
      :gen_tcp.connect({:local, sock}, 0, [:binary, {:active, false}, {:packet, 4}], 1_000)

    :ok = :gen_tcp.send(client, Jason.encode!(payload))
    {:ok, frame} = :gen_tcp.recv(client, 0, timeout)
    :gen_tcp.close(client)
    Jason.decode!(frame)
  end

  @doc """
  The durable state under the inbox (delivery/ and state/): every regular file and directory
  with its size, mtime and inode. Equal snapshots mean nothing durable was written.
  """
  def snapshot(inbox) do
    for dir <- ["delivery", "state"],
        path <- Path.wildcard(Path.join([inbox, dir, "**"]), match_dot: true),
        {:ok, stat} = File.lstat(path, time: :posix),
        into: %{} do
      {Path.relative_to(path, inbox), {stat.type, stat.size, stat.mtime, stat.inode}}
    end
  end

  def binding_for(root), do: %{project: "synthetic-project", project_dir: root, project_inbox: root}

  def stop_app! do
    sup = Process.whereis(AiPair.Supervisor)
    ref = if is_pid(sup), do: Process.monitor(sup)

    case Application.stop(:ai_pair) do
      :ok -> :ok
      {:error, {:not_started, :ai_pair}} -> :ok
      other -> raise "Application.stop(:ai_pair) returned #{inspect(other)}; shutdown unproven"
    end

    if ref do
      receive do
        {:DOWN, ^ref, :process, ^sup, _} -> :ok
      after
        5_000 -> raise "AiPair.Supervisor #{inspect(sup)} did not terminate; containment unproven"
      end
    end

    :telemetry.detach(AiPair.Telemetry.OtelBridge)
    :ok
  end

  defp restore_vars!(prior) do
    Enum.each(prior, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end

  defp restore_keys!(prior) do
    Enum.each(prior, fn
      {key, {:ok, value}} -> Application.put_env(:ai_pair, key, value)
      {key, :error} -> Application.delete_env(:ai_pair, key)
    end)
  end

  # The pane-intent store refuses a group- or world-readable state directory, so every
  # subdirectory the inbox resolver creates is created here at 0700 first.
  defp inbox_root! do
    inbox = Path.join(canonical_tmp(), "ai_pair_rb3a_g2_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(inbox) end)
    File.mkdir_p!(inbox)
    File.chmod!(inbox, 0o700)

    for name <- @inbox_subdirs do
      sub = Path.join(inbox, name)
      File.mkdir_p!(sub)
      File.chmod!(sub, 0o700)
    end

    inbox
  end

  defp canonical_tmp do
    System.tmp_dir!()
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce("/", fn seg, acc ->
      joined = Path.join(acc, seg)

      case File.read_link(joined) do
        {:ok, "/" <> _ = absolute} -> absolute
        {:ok, relative} -> Path.expand(Path.join(Path.dirname(joined), relative))
        {:error, _} -> joined
      end
    end)
  end

  # Removed only after the teardown proved containment (CONTAINED); otherwise retained.
  defp refusing_tmux_on_path! do
    dir = Path.join(canonical_tmp(), "tmux_refuse_rb3a_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      if File.exists?(Path.join(dir, "CONTAINED")),
        do: File.rm_rf!(dir),
        else: raise("containment unproven; refusing tmux wrapper retained at #{dir}")
    end)

    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    bin = Path.join(dir, "tmux")

    File.write!(bin, """
    #!/usr/bin/env bash
    cmd=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -L|-S|-f) shift 2 ;;
        -*) shift ;;
        *) cmd="$1"; break ;;
      esac
    done
    case "$cmd" in
      list-panes) exit 0 ;;
      show-options) printf 'invalid option: fixture empty server\\n' >&2; exit 1 ;;
      *) printf 'fixture tmux boundary refused\\n' >&2; exit 97 ;;
    esac
    """)

    File.chmod!(bin, 0o700)
    dir
  end
end
