defmodule AiPair.FingerprintUnlessTailTest do
  @moduledoc """
  Engine controls for the dialog state's `unless_tail` key (design
  D/rb/CODEX-DIALOG-FINGERPRINT-DESIGN-r6.org, D-1 and C-1). The exemption is all or
  nothing: every malformed list below keeps valid surviving members that match the
  screen's last lines, so dropping the bad member (or shortening N) would exempt and
  return :idle; the required result is :dialog.
  """

  use ExUnit.Case, async: true

  alias AiPair.Fingerprint

  defp fp(dialog_extra \\ %{}, busy_extra \\ %{}, idle_extra \\ %{}) do
    %{
      "states" => %{
        "dialog" => Map.merge(%{"bottom_lines" => 14, "any" => ["DLG"]}, dialog_extra),
        "busy" => Map.merge(%{"bottom_lines" => 14, "any" => ["BUSY"]}, busy_extra),
        "idle" => Map.merge(%{"bottom_lines" => 14, "any" => ["^›"]}, idle_extra)
      }
    }
  end

  defp with_tail(value), do: fp(%{"unless_tail" => value})

  @s "x DLG\n› ok\ns\n"
  @t "\n\nx DLG\n\n  \ns\n\n"
  @b "BUSY\n› ok\ns\n"
  @i "y\n› ok\ns\n"

  test "the screen S classifies :dialog without unless_tail" do
    assert Fingerprint.match(@s, fp()) == {:ok, :dialog}
  end

  test "group 1: absent, null, empty and non-list values grant no exemption" do
    for value <- [nil, [], "^s$", %{"a" => "^s$"}, 7, ["^s$" | "^s$"]] do
      assert Fingerprint.match(@s, with_tail(value)) == {:ok, :dialog}, inspect(value)
    end
  end

  test "group 2: a non-string member beside a surviving suffix voids the whole list" do
    for value <- [["^s$", 7], [7, "^s$"], ["^s$", nil], [nil, "^s$"]] do
      assert Fingerprint.match(@s, with_tail(value)) == {:ok, :dialog}, inspect(value)
    end
  end

  test "group 3: an invalid regex in either position voids the whole list" do
    for value <- [["(", "^s$"], ["^s$", "("]] do
      assert Fingerprint.match(@s, with_tail(value)) == {:ok, :dialog}, inspect(value)
    end
  end

  test "group 4: several valid survivors never shorten N" do
    for value <- [
          ["^› ok$", "^s$", 7],
          ["(", "^› ok$", "^s$"],
          [nil, "^x DLG$", "^› ok$", "^s$"]
        ] do
      assert Fingerprint.match(@s, with_tail(value)) == {:ok, :dialog}, inspect(value)
    end
  end

  test "group 5: a valid list matching the last lines in order exempts the dialog state" do
    assert Fingerprint.match(@s, with_tail(["^x DLG$", "^› ok$", "^s$"])) == {:ok, :idle}
  end

  test "group 6: a screen with fewer than N non-blank lines grants no exemption" do
    assert Fingerprint.match(@t, fp()) == {:ok, :dialog}

    for value <- [["^x DLG$", "^s$", "^s$"], ["^q$", "^x DLG$", "^s$"]] do
      assert Fingerprint.match(@t, with_tail(value)) == {:ok, :dialog}, inspect(value)
    end
  end

  test "group 7: wrong order or one mismatch grants no exemption" do
    for value <- [["^› ok$", "^x DLG$", "^s$"], ["^x DLG$", "^› ok$", "^t$"]] do
      assert Fingerprint.match(@s, with_tail(value)) == {:ok, :dialog}, inspect(value)
    end
  end

  test "group 8: busy ignores unless_tail, valid or malformed" do
    for value <- [["^BUSY$", "^› ok$", "^s$"], ["^s$", 7]] do
      assert Fingerprint.match(@b, fp(%{}, %{"unless_tail" => value})) == {:ok, :busy},
             inspect(value)
    end
  end

  test "group 8: idle ignores unless_tail, valid or malformed" do
    for value <- [["^y$", "^› ok$", "^s$"], ["^s$", 7]] do
      assert Fingerprint.match(@i, fp(%{}, %{}, %{"unless_tail" => value})) == {:ok, :idle},
             inspect(value)
    end

    idle_only = %{
      "states" => %{
        "idle" => %{
          "bottom_lines" => 14,
          "any" => ["^›"],
          "unless_tail" => ["^y$", "^› ok$", "^s$"]
        }
      }
    }

    assert Fingerprint.match(@i, idle_only) == {:ok, :idle}
  end
end
