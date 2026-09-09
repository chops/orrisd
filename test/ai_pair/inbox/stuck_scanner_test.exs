defmodule AiPair.Inbox.StuckScannerTest do
  use ExUnit.Case, async: false

  alias AiPair.Inbox.StuckScanner

  setup do
    tmp = Path.join(System.tmp_dir!(), "ai_pair_stuck_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "inbox"))
    on_exit(fn -> File.rm_rf!(tmp) end)

    ref = make_ref()
    handler_id = {:stuck_scanner_test, ref}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:ai_pair, :inbox, :stuck],
      fn _event, measurements, meta, _config ->
        send(test_pid, {:stuck, ref, measurements, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    %{inbox: tmp, ref: ref}
  end

  test "emits stuck telemetry for role-only envelope older than threshold", %{
    inbox: inbox,
    ref: ref
  } do
    msg_id = "m_test_stuck_role"
    envelope_path = Path.join([inbox, "inbox", "#{msg_id}.json"])

    File.write!(
      envelope_path,
      Jason.encode!(%{
        "schema_version" => "1.0",
        "msg_id" => msg_id,
        "ts" => "2026-05-15T00:00:00Z",
        "from" => %{"agent" => "claude"},
        "to" => %{"agent" => "codex"},
        "kind" => "note",
        "body" => "test"
      })
    )

    backdate(envelope_path, 400)

    {:ok, pid} =
      StuckScanner.start_link(
        name: :"stuck_scanner_#{System.unique_integer([:positive])}",
        inbox: inbox,
        poll_interval_ms: 50,
        age_threshold_ms: 300_000
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:stuck, ^ref, %{age_s: age_s},
                    %{pane_id: nil, msg_id: ^msg_id, path: ^envelope_path}},
                   1_000

    assert age_s >= 300
  end

  test "does not emit for fresh envelopes", %{inbox: inbox, ref: ref} do
    msg_id = "m_test_fresh"
    envelope_path = Path.join([inbox, "inbox", "#{msg_id}.json"])

    File.write!(
      envelope_path,
      Jason.encode!(%{
        "schema_version" => "1.0",
        "msg_id" => msg_id,
        "ts" => "2026-05-15T00:00:00Z",
        "from" => %{"agent" => "claude"},
        "to" => %{"agent" => "codex"},
        "kind" => "note",
        "body" => "test"
      })
    )

    {:ok, pid} =
      StuckScanner.start_link(
        name: :"stuck_scanner_fresh_#{System.unique_integer([:positive])}",
        inbox: inbox,
        poll_interval_ms: 30,
        age_threshold_ms: 60_000
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    refute_receive {:stuck, ^ref, _, _}, 150
  end

  defp backdate(path, seconds_ago) do
    epoch_now = System.system_time(:second)
    target = epoch_now - seconds_ago
    File.touch!(path, target)
  end
end
