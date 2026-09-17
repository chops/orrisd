defmodule AiPair.TmuxTest do
  use ExUnit.Case, async: false

  alias AiPair.Tmux

  setup context do
    socket_name = "ai_pair_test_#{System.unique_integer([:positive])}"
    locale = context[:tmux_locale]
    env = if locale, do: [{"LC_ALL", locale}], else: []

    {tmux_bin, 0} = System.cmd("which", ["tmux"])
    tmux_bin = String.trim(tmux_bin)

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

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
      end

      System.cmd(tmux_bin, ["-L", socket_name, "kill-server"], stderr_to_stdout: true)
    end)

    {:ok, server: server_name, socket_name: socket_name, tmux_bin: tmux_bin, locale: locale}
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
