defmodule AiPair.Admission.MarkerSourceTest.Intent do
  @moduledoc false
  # A stand-in pane-intent store: answers :list from its start argument.
  use GenServer
  def start(reply), do: GenServer.start(__MODULE__, reply)
  @impl true
  def init(reply), do: {:ok, reply}
  @impl true
  def handle_call(:list, _from, reply), do: {:reply, reply, reply}
end

defmodule AiPair.Admission.MarkerSourceTest do
  @moduledoc """
  NS-32.M.002 RB-3a GREEN-2, design r4 W4: AiPair.Admission.MarkerSource derives the session set
  from the committed records and ONE census, and certifies one marker version or `:error`
  (observation_incomplete naming session_marker). Every rule step, with a stand-in intent store,
  census and marker reader.
  """

  use ExUnit.Case, async: true

  # A tmux pane id built at run time: the redaction scanner rejects pane-id literals in source.
  defp p(n), do: "%" <> Integer.to_string(n)

  alias AiPair.Admission.MarkerSource
  alias AiPair.Admission.MarkerSourceTest.Intent

  defp record(pane), do: %{"pane_id" => pane}
  defp row(pane, session), do: %{pane_id: pane, session_id: session}

  defp observe(records, census, markers) do
    {:ok, intent} = Intent.start(records)
    on_exit(fn -> if Process.alive?(intent), do: GenServer.stop(intent) end)

    MarkerSource.observe(%{
      intent: intent,
      tmux: :unused,
      census: fn -> census end,
      read_marker: fn session -> Map.get(markers, session, {:error, {:marker_absent}}) end
    })
  end

  defp marker(version),
    do: {:ok, %{version: version, owner_root: "/r", session_id: "$1", generation: "1"}}

  test "one committed pane in one session certifies that marker's version" do
    assert observe({:ok, [record(p(1))]}, {:ok, [row(p(1), "$1")]}, %{"$1" => marker(1)}) ==
             {:ok, 1}
  end

  test "two sessions whose markers agree certify the shared version" do
    census = {:ok, [row(p(1), "$1"), row(p(2), "$2")]}
    markers = %{"$1" => marker(1), "$2" => marker(1)}
    assert observe({:ok, [record(p(1)), record(p(2))]}, census, markers) == {:ok, 1}
  end

  test "two sessions whose markers disagree on version are :error" do
    census = {:ok, [row(p(1), "$1"), row(p(2), "$2")]}
    markers = %{"$1" => marker(1), "$2" => marker(2)}
    assert observe({:ok, [record(p(1)), record(p(2))]}, census, markers) == :error
  end

  test "no committed record is :error (no attached session to certify)" do
    assert observe({:ok, []}, {:ok, [row(p(1), "$1")]}, %{"$1" => marker(1)}) == :error
  end

  test "a failed intent read is :error" do
    assert observe({:error, :unavailable}, {:ok, [row(p(1), "$1")]}, %{"$1" => marker(1)}) == :error
  end

  test "a failed census is :error" do
    assert observe({:ok, [record(p(1))]}, {:error, :census}, %{"$1" => marker(1)}) == :error
  end

  test "a committed pane missing from the census is :error" do
    census = {:ok, [row(p(1), "$1")]}
    assert observe({:ok, [record(p(1)), record(p(2))]}, census, %{"$1" => marker(1)}) == :error
  end

  test "a committed pane observed twice across two sessions is :error even when the markers agree" do
    census = {:ok, [row(p(1), "$1"), row(p(1), "$2")]}
    markers = %{"$1" => marker(1), "$2" => marker(1)}
    assert observe({:ok, [record(p(1))]}, census, markers) == :error
  end

  test "a committed pane observed twice in one session is :error" do
    census = {:ok, [row(p(1), "$1"), row(p(1), "$1")]}
    assert observe({:ok, [record(p(1))]}, census, %{"$1" => marker(1)}) == :error
  end

  test "a census row without a session id is :error" do
    census = {:ok, [%{pane_id: p(1), session_id: nil}]}
    assert observe({:ok, [record(p(1))]}, census, %{}) == :error
  end

  test "one of two markers absent is :error" do
    census = {:ok, [row(p(1), "$1"), row(p(2), "$2")]}
    assert observe({:ok, [record(p(1)), record(p(2))]}, census, %{"$1" => marker(1)}) == :error
  end

  test "a malformed marker is :error" do
    markers = %{"$1" => {:error, {:marker_malformed, "{"}}}
    assert observe({:ok, [record(p(1))]}, {:ok, [row(p(1), "$1")]}, markers) == :error
  end

  test "a reader that exits is :error" do
    {:ok, intent} = Intent.start({:ok, [record(p(1))]})

    assert MarkerSource.observe(%{
             intent: intent,
             tmux: :unused,
             census: fn -> {:ok, [row(p(1), "$1")]} end,
             read_marker: fn _ -> exit(:reader_down) end
           }) == :error
  end
end
