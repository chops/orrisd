defmodule AiPair.Delivery.PayloadTest do
  use ExUnit.Case, async: true

  alias AiPair.Delivery.{Payload, ReceiptStore}
  alias AiPair.Pane.StateMachine

  @bytes "private delivery body that must not appear in inspection"

  test "ordinary nested inspection is redacted and serialization is refused" do
    payload = Payload.new(@bytes)
    assert Payload.reveal(payload) == @bytes

    assert Payload.hash(payload) ==
             "sha256:" <> Base.encode16(:crypto.hash(:sha256, @bytes), case: :lower)

    output = inspect({:queued, [payload]}, limit: :infinity, printable_limit: :infinity)
    refute output =~ @bytes
    assert output =~ Payload.hash(payload)
    assert_raise Protocol.UndefinedError, fn -> Jason.encode!(payload) end
    assert_raise Protocol.UndefinedError, fn -> apply(String.Chars, :to_string, [payload]) end
  end

  test "receipted public calls keep queue inspection free of the prompt" do
    inbox = Path.join(System.tmp_dir!(), "payload-#{System.unique_integer([:positive])}")
    File.mkdir_p!(inbox)
    on_exit(fn -> File.rm_rf!(inbox) end)
    store = start_supervised!({ReceiptStore, inbox: inbox})

    {:ok, pane} =
      StateMachine.start_link(
        pane_id: "%payload",
        receipt_store: store,
        capture_fn: fn _ -> {:ok, "BUSY_MARKER"} end,
        paste_fn: fn _, _ -> :ok end,
        classifier: AiPair.Test.MarkerClassifier,
        poll_interval_ms: 5
      )

    for {method, suffix} <- [{:send_receipted, "a"}, {:send_text, "b"}] do
      id = "snd_" <> String.duplicate(suffix, 64)

      result =
        if method == :send_receipted,
          do: StateMachine.send_receipted(pane, @bytes, 1_000, id, store),
          else: StateMachine.send_text(pane, @bytes, 1_000, id)

      assert match?({:queued, _}, result)
    end

    assert StateMachine.pending_count(pane) == 2
    refute inspect(:sys.get_state(pane), limit: :infinity, printable_limit: :infinity) =~ @bytes
    :gen_statem.stop(pane)
  end
end
