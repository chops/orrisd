defmodule AiPair.TmuxTest do
  @moduledoc """
  The rows that bind `AiPair.Tmux` to a REAL tmux server.

  Every row here asserts something about tmux itself - what it emits, what it
  accepts, how it words a refusal - so none of them can be served by the
  scripted fake that `AiPair.TmuxCensusTest` and `AiPair.Test.ScriptedTmux`
  use. The fake's frozen fixture (`test/fixtures/tmux/observe_panes.*`) is
  bytes this repository wrote; it pins the PARSER against a transcription of
  tmux's format, and only these rows pin that transcription against tmux.

  What DID have to change is how many servers that costs. The suite used to
  start one private server per row - eight `new-session` execs in a full
  `bin/verify`, measured - because the server was built in `setup`. Nothing
  about the assertions needed that: a single detached session running `sleep`
  serves all of them, and rows in one module run sequentially, so the only
  cross-row hazard is a row that MUTATES the shared session. Exactly one does
  (the separator row renames it) and it restores the bootstrap name in an
  `on_exit` registered before the rename.

  The Unicode row is the one row that cannot share, and not for a reason of
  convenience: it needs the tmux SERVER PROCESS to have been started under a
  UTF-8 locale, which is a property of `new-session`'s environment and cannot
  be applied to a server that is already running. It therefore starts its own,
  and the module's cost is two servers rather than eight. Both carry `-L`, so
  neither can address the operator's default server;
  `AiPair.TestContainmentControlTest` fails if either fact stops holding.
  """
  use ExUnit.Case, async: false

  alias AiPair.Tmux

  setup_all do
    {tmux_bin, 0} = System.cmd("which", ["tmux"])
    tmux_bin = String.trim(tmux_bin)

    shared = start_server!(tmux_bin, [])
    on_exit(fn -> stop_server!(shared) end)

    {:ok, tmux_bin: tmux_bin, shared: shared}
  end

  setup context do
    case context[:tmux_locale] do
      nil ->
        {:ok,
         server: context.shared.server,
         socket_name: context.shared.socket_name,
         tmux_bin: context.tmux_bin,
         locale: nil}

      locale ->
        own = start_server!(context.tmux_bin, [{"LC_ALL", locale}])
        on_exit(fn -> stop_server!(own) end)

        {:ok,
         server: own.server,
         socket_name: own.socket_name,
         tmux_bin: context.tmux_bin,
         locale: locale}
    end
  end

  # A private server (`-L`) running one detached session called `test` whose
  # only pane runs `sleep`, plus an adapter scoped to that socket. `-f /dev/null`
  # keeps the operator's tmux.conf out of it.
  defp start_server!(tmux_bin, env) do
    socket_name = "ai_pair_test_#{System.unique_integer([:positive])}"

    {_, 0} =
      System.cmd(
        tmux_bin,
        [
          "-L",
          socket_name,
          "-f",
          "/dev/null",
          "new-session",
          "-d",
          "-s",
          "test",
          "-x",
          "80",
          "-y",
          "24",
          "sleep",
          "3600"
        ],
        env: env
      )

    server_name = String.to_atom("tmux_test_#{System.unique_integer([:positive])}")
    {:ok, pid} = Tmux.start_link(name: server_name, socket_name: socket_name, tmux_bin: tmux_bin)

    %{server: server_name, socket_name: socket_name, pid: pid, tmux_bin: tmux_bin}
  end

  defp stop_server!(%{pid: pid, tmux_bin: tmux_bin, socket_name: socket_name}) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end

    System.cmd(tmux_bin, ["-L", socket_name, "kill-server"], stderr_to_stdout: true)
    :ok
  end

  test "list_panes returns the bootstrap session's pane", %{server: server} do
    {:ok, panes} = Tmux.list_panes(server)
    assert [pane] = panes
    assert String.starts_with?(pane.id, "%")
    assert pane.session == "test"
    assert pane.window == 0
    assert pane.pane == 0
    assert is_integer(pane.pid) and pane.pid > 0
    assert is_binary(pane.command) and pane.command != ""
  end

  test "set_buffer + paste_buffer + delete_buffer cycle", %{server: server} do
    {:ok, [pane]} = Tmux.list_panes(server)
    name = "ai_pair_test_buf"

    assert :ok = Tmux.set_buffer(name, "hello\nworld\n", server)
    assert :ok = Tmux.paste_buffer(pane.id, name, [delete: true], server)
    assert {:error, %{status: 1}} = Tmux.delete_buffer(name, server)
  end

  test "list_panes preserves printable separators and literal escape sequences", %{
    server: server,
    socket_name: socket_name,
    tmux_bin: tmux_bin
  } do
    session = "test|%7C%25"

    # The server is shared with the rest of the module, so this row hands the
    # bootstrap session name back. Registered BEFORE the rename so a row that
    # fails mid-way still restores it, and the restoration is OBSERVED rather
    # than assumed: a rename that silently failed would otherwise surface as an
    # unrelated row failing on `pane.session == "test"`.
    on_exit(fn ->
      _ =
        System.cmd(tmux_bin, ["-L", socket_name, "rename-session", "-t", session, "test"],
          stderr_to_stdout: true
        )

      {names, 0} =
        System.cmd(tmux_bin, ["-L", socket_name, "list-sessions", "-F", "\#{session_name}"],
          stderr_to_stdout: true
        )

      assert String.trim(names) == "test",
             "the shared server must be handed back carrying only its bootstrap session"
    end)

    assert {_, 0} =
             System.cmd(tmux_bin, ["-L", socket_name, "rename-session", "-t", "test", session])

    assert {:ok, [pane]} = Tmux.list_panes(server)
    assert pane.session == session
  end

  @tag tmux_locale: if(:os.type() == {:unix, :darwin}, do: "en_US.UTF-8", else: "C.UTF-8")
  test "list_panes preserves a Unicode session under a UTF-8 locale", %{
    server: server,
    socket_name: socket_name,
    tmux_bin: tmux_bin,
    locale: locale
  } do
    previous = System.get_env("LC_ALL")
    System.put_env("LC_ALL", locale)

    on_exit(fn ->
      if previous, do: System.put_env("LC_ALL", previous), else: System.delete_env("LC_ALL")
    end)

    session = "test|%7C%25\u00e9"

    assert {_, 0} =
             System.cmd(tmux_bin, ["-L", socket_name, "rename-session", "-t", "test", session])

    assert {:ok, [pane]} = Tmux.list_panes(server)
    assert pane.session == session
  end

  test "send_keys delivers control keys", %{server: server} do
    {:ok, [pane]} = Tmux.list_panes(server)
    assert :ok = Tmux.send_keys(pane.id, ["Enter"], server)
  end

  test "capture_pane returns binary content", %{server: server} do
    {:ok, [pane]} = Tmux.list_panes(server)
    assert {:ok, content} = Tmux.capture_pane(pane.id, [], server)
    assert is_binary(content)
  end

  test "capture_pane against a missing pane returns the typed :pane_gone atom", %{server: server} do
    assert {:error, :pane_gone} = Tmux.capture_pane("%99999", [], server)
  end

  test "display_message succeeds against a valid pane", %{server: server} do
    {:ok, [pane]} = Tmux.list_panes(server)
    assert :ok = Tmux.display_message(pane.id, "tmux boundary smoke", server)
  end
end

defmodule AiPair.TmuxPaneListCodecTest do
  use ExUnit.Case, async: true

  test "decodes both free-text fields without recursively decoding escapes or dropping Unicode" do
    root = Path.join(System.tmp_dir!(), "tmux_codec_#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    stub = Path.join(root, "tmux-fixture")

    File.write!(
      stub,
      "#!/usr/bin/env bash\nprintf '%s\\n' " <>
        "'%fixture|session%7C%257C%2525\u00e9|2|3|42|cmd%7C%257C%2525\u00e9' 'malformed'\n"
    )

    File.chmod!(stub, 0o700)
    name = String.to_atom("tmux_codec_#{System.unique_integer([:positive])}")
    start_supervised!({AiPair.Tmux, name: name, tmux_bin: stub})

    assert {:ok,
            [
              %{
                id: "%fixture",
                session: "session|%7C%25\u00e9",
                window: 2,
                pane: 3,
                pid: 42,
                command: "cmd|%7C%25\u00e9"
              }
            ]} = AiPair.Tmux.list_panes(name)
  end
end
