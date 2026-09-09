defmodule AiPair.InboxTest do
  use ExUnit.Case, async: false

  import AiPair.Test.OtelHelper

  alias AiPair.Inbox

  setup do
    prior = System.get_env("AI_PAIR_INBOX")

    on_exit(fn ->
      if prior, do: System.put_env("AI_PAIR_INBOX", prior), else: System.delete_env("AI_PAIR_INBOX")
    end)

    :ok
  end

  test "resolve! creates the directory and required subdirs" do
    tmp = Path.join(System.tmp_dir!(), "ai_pair_inbox_test_#{System.unique_integer([:positive])}")
    System.put_env("AI_PAIR_INBOX", tmp)

    on_exit(fn -> File.rm_rf!(tmp) end)

    assert Inbox.resolve!() == Path.expand(tmp)
    assert File.dir?(Path.join(tmp, "sock"))
    assert File.dir?(Path.join(tmp, "fingerprints"))
    assert File.dir?(Path.join(tmp, "logs"))
    assert File.dir?(Path.join(tmp, "state"))
    assert File.dir?(Path.join(tmp, "inbox"))
    assert File.dir?(Path.join(tmp, "outbox"))
    assert File.dir?(Path.join(tmp, "processed"))
  end

  test "resolve! chmods sock/ to 0o700" do
    tmp = Path.join(System.tmp_dir!(), "ai_pair_sock_perms_#{System.unique_integer([:positive])}")
    System.put_env("AI_PAIR_INBOX", tmp)

    on_exit(fn -> File.rm_rf!(tmp) end)

    Inbox.resolve!()

    %File.Stat{mode: mode} = File.stat!(Path.join(tmp, "sock"))
    assert Bitwise.band(mode, 0o777) == 0o700
  end

  test "resolve! refuses paths under a source tree" do
    System.put_env("AI_PAIR_INBOX", Path.join([System.user_home!(), "src", "ai-pair", "runtime"]))

    assert_raise RuntimeError, ~r/source tree|mix project/, fn -> Inbox.resolve!() end
  end

  test "resolve! refuses paths under a mix project" do
    tmp = Path.join(System.tmp_dir!(), "mp_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "mix.exs"), "defmodule X do end")
    nested = Path.join(tmp, "inbox")
    System.put_env("AI_PAIR_INBOX", nested)

    on_exit(fn -> File.rm_rf!(tmp) end)

    assert_raise RuntimeError, ~r/mix project/, fn -> Inbox.resolve!() end
  end

  test "default_path is rooted under $HOME" do
    assert Inbox.default_path() == Path.join(System.user_home!(), ".ai-agent-inbox/ai-pair")
  end

  test "resolve! emits inbox.resolve span with source=env attribute on success" do
    setup_otel_capture()

    tmp = Path.join(System.tmp_dir!(), "ai_pair_inbox_otel_#{System.unique_integer([:positive])}")
    System.put_env("AI_PAIR_INBOX", tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    Inbox.resolve!()

    assert {:ok, span} = assert_span(name: "inbox.resolve")
    attrs = span_attrs(span)
    assert attrs["inbox.source"] == "env"
    assert attrs["inbox.path"] == Path.expand(tmp)
    refute Map.has_key?(attrs, "inbox.error_reason")
  end

  test "resolve! tags inbox.resolve span with mix_project reason when raising" do
    setup_otel_capture()

    tmp = Path.join(System.tmp_dir!(), "mp_otel_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "mix.exs"), "defmodule X do end")
    nested = Path.join(tmp, "inbox")
    System.put_env("AI_PAIR_INBOX", nested)
    on_exit(fn -> File.rm_rf!(tmp) end)

    assert_raise RuntimeError, ~r/mix project/, fn -> Inbox.resolve!() end

    assert {:ok, span} = assert_span(name: "inbox.resolve")
    attrs = span_attrs(span)
    assert attrs["inbox.error_reason"] == "mix_project"
  end

  test "resolve! tags inbox.resolve span with source_tree reason when raising" do
    setup_otel_capture()

    System.put_env("AI_PAIR_INBOX", Path.join([System.user_home!(), "src", "ai-pair", "runtime"]))

    assert_raise RuntimeError, ~r/source tree|mix project/, fn -> Inbox.resolve!() end

    assert {:ok, span} = assert_span(name: "inbox.resolve")
    attrs = span_attrs(span)
    assert attrs["inbox.error_reason"] in ~w(source_tree mix_project)
  end

  test "resolve! refuses a symlink that resolves into a mix project" do
    tmp = Path.join(System.tmp_dir!(), "mp_link_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "mix.exs"), "defmodule X do end")

    target_inside_project = Path.join(tmp, "runtime")
    File.mkdir_p!(target_inside_project)

    link = Path.join(System.tmp_dir!(), "ai_pair_link_#{System.unique_integer([:positive])}")
    File.ln_s!(target_inside_project, link)
    System.put_env("AI_PAIR_INBOX", link)

    on_exit(fn ->
      File.rm_rf!(tmp)
      File.rm_rf!(link)
    end)

    assert_raise RuntimeError, ~r/mix project/, fn -> Inbox.resolve!() end
  end
end
