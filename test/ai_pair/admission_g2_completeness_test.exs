defmodule AiPair.AdmissionG2CompletenessTest do
  @moduledoc """
  NS-32.M.002 RB-3a GREEN-2, design r4 W5 "Completeness": every entry of the G1 pinned caller
  inventory (AiPair.AdmissionInventoryTest) maps to at least one G2 runtime row, every mapped row
  exists in the G2 row files, and every G2 row cites a G1 entry or a declared non-mutating
  witness. A new G1 entry, a removed row or an uncited row fails here.

  tmux.ex begin_command runs only inside the gated transaction of a released child's matched
  restored entry; row 4g drives it through the production release, after the F-1 fix bound the
  released child's classifier to its proved record (RB-3a GREEN-2 F-1 design r2).
  """

  use ExUnit.Case, async: true

  @inventory Path.expand("admission_inventory_test.exs", __DIR__)
  @rows [
    Path.expand("admission_g2_paths_test.exs", __DIR__),
    Path.expand("admission_g2_failstop_test.exs", __DIR__)
  ]

  # G1 entry => the G2 rows (describe names, by prefix) that witness it at runtime.
  @coverage %{
    {"ai_pair/ipc/server.ex", "PaneIntentStore.put"} => ["rows 6 and 7"],
    {"ai_pair/ipc/server.ex", "PaneIntentStore.delete"} => ["rows 6 and 7"],
    {"ai_pair/ipc/server.ex", "Marker.ensure"} => ["rows 6 and 7"],
    {"ai_pair/pane/state_machine.ex", "ReceiptStore.admit"} => ["row 2:", "row 3:"],
    {"ai_pair/pane/state_machine.ex", "ReceiptStore.queue"} => ["row 4:"],
    {"ai_pair/pane/state_machine.ex", "ReceiptStore.begin_paste"} => [
      "row 2:",
      "row 3:",
      "row 4:",
      "row 5:",
      "row 5b:"
    ],
    {"ai_pair/tmux.ex", "ReceiptStore.begin_command"} => ["row 4g:"]
  }

  # Rows that witness a ticket or the wiring rather than one G1 call site.
  @non_mutating ["row 1:", "row 8:", "row 9:", "W5 row 10:", "W1 failure matrix"]

  defp g1_entries do
    ~r/\{"([a-z_\/]+\.ex)", "([A-Za-z_.]+)"\} =>/
    |> Regex.scan(File.read!(@inventory))
    |> Enum.map(fn [_, file, call] -> {file, call} end)
    |> MapSet.new()
  end

  defp describes do
    for path <- @rows, [_, name] <- Regex.scan(~r/describe "([^"]+)"/, File.read!(path)), do: name
  end

  test "every G1 entry has a G2 row and nothing in the coverage is outside G1" do
    entries = g1_entries()
    assert MapSet.size(entries) == 7, "the G1 inventory changed: #{inspect(entries)}"
    assert MapSet.new(Map.keys(@coverage)) == entries
  end

  test "every row the coverage names exists in a G2 row file" do
    names = describes()

    for {entry, prefixes} <- @coverage, prefix <- prefixes do
      assert Enum.any?(names, &String.starts_with?(&1, prefix)),
             "#{inspect(entry)} cites #{prefix}, which no G2 row file declares"
    end
  end

  test "every G2 row cites a G1 entry or is a declared non-mutating witness" do
    cited = @coverage |> Map.values() |> List.flatten()

    for name <- describes() do
      assert Enum.any?(cited ++ @non_mutating, &String.starts_with?(name, &1)),
             "G2 row \"#{name}\" cites no G1 entry and is not declared non-mutating"
    end
  end

  test "the scanners are not vacuous" do
    assert MapSet.member?(g1_entries(), {"ai_pair/tmux.ex", "ReceiptStore.begin_command"})
    assert length(describes()) >= 10
  end
end
