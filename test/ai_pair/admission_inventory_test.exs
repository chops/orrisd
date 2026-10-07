defmodule AiPair.AdmissionInventoryTest do
  @moduledoc """
  NS-32.M.002 RB-3a GREEN guard G1 (producer RED scope r3; split DESIGN GO m_20261007T162730Z):
  a static inventory of every direct caller, in lib/, of the APIs that start a durable mutation
  or a paste: ReceiptStore admit, queue, begin_paste and begin_command; PaneIntentStore put and
  delete; Marker.ensure. A caller not in the pinned list fails, so a new path cannot appear
  without being placed under an AiPair.Admission ticket and reviewed.

  LIMIT, stated: this proves ENUMERATION only, never that a caller runs under a ticket. The
  runtime witness of each path (guard G2) is completed by RB-3a GREEN-2, which wires the daemon;
  until then the ticket column below is the reviewed claim, not a proof.
  """

  use ExUnit.Case, async: true

  @lib Path.expand("../../lib", __DIR__)

  @calls ~r/(ReceiptStore\.(?:admit|queue|begin_paste|begin_command)|PaneIntentStore\.(?:put|delete)|Marker\.ensure)\(/

  # {file relative to lib/, call} => {count, the ticket that covers it}
  @pinned %{
    {"ai_pair/ipc/server.ex", "PaneIntentStore.delete"} => {1, "v1 detach_pane (:detach_pane)"},
    {"ai_pair/ipc/server.ex", "PaneIntentStore.put"} => {1, "v1 attach_pane (:attach_pane)"},
    {"ai_pair/ipc/server.ex", "Marker.ensure"} => {1, "v1 attach_pane (:attach_pane)"},
    {"ai_pair/pane/state_machine.ex", "ReceiptStore.admit"} =>
      {2, "the IPC send that called send_receipted (:ipc_send)"},
    {"ai_pair/pane/state_machine.ex", "ReceiptStore.queue"} =>
      {1, "the IPC send that called send_receipted (:ipc_send)"},
    {"ai_pair/pane/state_machine.ex", "ReceiptStore.begin_paste"} =>
      {2, "an immediate paste inside the IPC send (:ipc_send) or a queued paste (:idle_paste)"},
    {"ai_pair/tmux.ex", "ReceiptStore.begin_command"} =>
      {1, "the gated paste inside a paste that holds a ticket (:idle_paste or :release)"}
  }

  # Direct GenServer messages to the store would bypass the named API; none may exist outside it.
  @raw_messages ~r/\{:(?:admit|queue|begin_paste|begin_command),/

  defp sources do
    @lib
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&{Path.relative_to(&1, @lib), File.read!(&1)})
  end

  test "G1 every direct caller of a mutating store, pane-intent or marker API is in the pinned inventory" do
    found =
      for {file, text} <- sources(),
          [_, call] <- Regex.scan(@calls, text),
          reduce: %{} do
        acc -> Map.update(acc, {file, call}, 1, &(&1 + 1))
      end

    pinned = Map.new(@pinned, fn {key, {count, _ticket}} -> {key, count} end)

    assert found == pinned,
           "unlisted or changed callers: " <>
             inspect(Map.drop(found, Map.keys(pinned))) <>
             " / pinned but not found: " <> inspect(Map.drop(pinned, Map.keys(found)))
  end

  test "G1 no module but the receipt store sends the store's mutating messages directly" do
    offenders =
      for {file, text} <- sources(),
          file != "ai_pair/delivery/receipt_store.ex",
          Regex.match?(@raw_messages, text),
          do: file

    assert offenders == []
  end

  test "G1 the scanners are not vacuous: a synthetic caller and a raw message are both detected" do
    synthetic =
      "x = ReceiptStore.admit(store, id)\nMarker.ensure(t, s, [])\nGenServer.call(s, {:queue, id})"

    assert [[_, "ReceiptStore.admit"], [_, "Marker.ensure"]] = Regex.scan(@calls, synthetic)
    assert Regex.match?(@raw_messages, synthetic)
  end

  test "G1 every pinned caller names the admission ticket that covers it" do
    for {{file, call}, {count, ticket}} <- @pinned do
      assert count > 0 and is_binary(ticket) and ticket =~ ~r/\(:[a-z_]+/, "#{file} #{call}"
    end
  end
end
