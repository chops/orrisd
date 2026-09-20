defmodule AiPair.IPC.SessionsContractFixtureTest do
  use ExUnit.Case, async: false

  alias AiPair.IPC.Sessions
  alias AiPair.Test.RouteGuard

  @fixture_dir Path.expand("../../fixtures/contracts/ipc/v2-sessions", __DIR__)
  @fixture_hash "5d81dcb70a06c1219854992abeabbd13a1db709dd9fa04d3d8331cc33f01271e"
  @request %{"cmd" => "sessions", "protocol_version" => 2}
  @limit 1_048_576
  @fixtures ~w(
    oversize.json
    sessions.error.invalid_sessions_census.json
    sessions.error.invalid_sessions_request.json
    sessions.error.sessions_unavailable.json
    sessions.ok.duplicate_names.json
    sessions.ok.empty.json
    sessions.ok.escaped_names.json
    sessions.ok.linked_window.json
    sessions.ok.mixed_registration.json
    sessions.ok.multi_address_consistency.json
    sessions.ok.multiple_sessions.json
    sessions.ok.ordering.json
  )
  @successes ~w(
    sessions.ok.duplicate_names.json
    sessions.ok.empty.json
    sessions.ok.escaped_names.json
    sessions.ok.linked_window.json
    sessions.ok.mixed_registration.json
    sessions.ok.multi_address_consistency.json
    sessions.ok.multiple_sessions.json
    sessions.ok.ordering.json
  )

  setup do
    RouteGuard.install!()
    :ok
  end

  test "the fixture inventory and bytes are the twelve canonical examples" do
    actual_names =
      @fixture_dir
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()

    assert actual_names == @fixtures

    payload =
      Enum.map(@fixtures, fn name ->
        [name, 0, File.read!(Path.join(@fixture_dir, name)), 0]
      end)

    assert Base.encode16(:crypto.hash(:sha256, payload), case: :lower) == @fixture_hash
    assert File.read!(Path.join(@fixture_dir, "CONTRACT_HASH")) == @fixture_hash <> "\n"
  end

  for name <- @successes do
    test "real dispatch and encoding produce #{name} from independent census rows" do
      name = unquote(name)
      {rows, registered} = scenario(name)
      result = produce(@request, {:ok, rows}, registered, [:census, :registry])

      assert result.candidate["ok"] == true
      assert Sessions.valid_reply?(result.decoded)
      assert normalize_panes(result.decoded) == fixture(name)

      # Input order and registry-set construction cannot supply the required output order.
      reordered =
        produce(@request, {:ok, Enum.reverse(rows)}, registered, [:census, :registry])

      assert reordered.decoded == result.decoded
    end
  end

  test "invalid request fixture is emitted before either callback can run" do
    request = Map.put(@request, "project", "unsupported-project-filter")
    result = produce(request, {:ok, []}, MapSet.new(), [])
    assert result.decoded == fixture("sessions.error.invalid_sessions_request.json")
    assert_empty_positive_witness()
  end

  test "malformed and contradictory observations produce the invalid census fixture" do
    good = row(1, "$1", "alpha", 0, 0)

    cases = [
      {{:error, {:row_arity, 8, 7, 0}}, [:census]},
      {{:error, {:malformed_text, :path, "private-malformed-path"}}, [:census]},
      {{:ok, [good, good]}, [:census, :registry]},
      {{:ok, [good, %{row(2, "$1", "alpha", 0, 1) | session_name: "conflict"}]},
       [:census, :registry]},
      {{:ok, [%{good | pane_id: "%not-decimal"}]}, [:census, :registry]}
    ]

    for {census, events} <- cases do
      result = produce(@request, census, registered([1, 2]), events)
      assert result.decoded == fixture("sessions.error.invalid_sessions_census.json")
    end

    assert_empty_positive_witness()
  end

  test "census and registry failures both produce the unavailable fixture" do
    census_error = {:error, %{status: 1, stderr: "private census diagnostic"}}
    failed_census = produce(@request, census_error, MapSet.new(), [:census])
    assert failed_census.decoded == fixture("sessions.error.sessions_unavailable.json")

    failed_registry = produce(@request, {:ok, []}, :raise_registry, [:census, :registry])
    assert failed_registry.decoded == fixture("sessions.error.sessions_unavailable.json")
    assert_empty_positive_witness()
  end

  test "a real oversized candidate is encoded as the generic oversize fixture" do
    rows = [row(1, "$1", String.duplicate("a", @limit + 1), 0, 0)]
    result = produce(@request, {:ok, rows}, registered([1]), [:census, :registry])

    assert result.candidate["ok"] == true
    assert byte_size(Jason.encode!(result.candidate)) > @limit
    assert result.decoded == fixture("oversize.json")
    assert byte_size(result.wire) < 100
    assert_empty_positive_witness()
  end

  defp scenario("sessions.ok.empty.json"), do: {[], MapSet.new()}

  defp scenario("sessions.ok.multiple_sessions.json") do
    {
      [row(3, "$2", "beta", 0, 1), row(1, "$1", "alpha", 0, 0), row(2, "$2", "beta", 0, 0)],
      registered([3, 1, 2])
    }
  end

  defp scenario("sessions.ok.duplicate_names.json") do
    {[row(2, "$4", "alpha", 0, 0), row(1, "$3", "alpha", 0, 0)], registered([2, 1])}
  end

  defp scenario("sessions.ok.mixed_registration.json") do
    {[row(2, "$5", "alpha", 0, 1), row(1, "$5", "alpha", 0, 0)], registered([1])}
  end

  defp scenario("sessions.ok.linked_window.json") do
    {
      [row(2, "$7", "beta", 0, 1), row(1, "$7", "beta", 0, 0), row(1, "$6", "alpha", 0, 0)],
      registered([2, 1])
    }
  end

  defp scenario("sessions.ok.multi_address_consistency.json") do
    {
      [row(2, "$9", "beta", 0, 0), row(2, "$8", "alpha", 1, 0), row(2, "$8", "alpha", 0, 0)],
      registered([1])
    }
  end

  defp scenario("sessions.ok.ordering.json") do
    {
      [
        row(8, "$9", "epsilon", 0, 0),
        row(6, "$10", "gamma", 10, 0),
        row(7, "$2", "delta", 0, 0),
        row(4, "$10", "gamma", 0, 10),
        row(3, "$10", "gamma", 0, 2),
        row(5, "$10", "gamma", 2, 0),
        row(2, "$10", "gamma", 0, 1),
        row(1, "$10", "gamma", 0, 0)
      ],
      registered([8, 6, 4, 2, 7, 5, 1])
    }
  end

  defp scenario("sessions.ok.escaped_names.json") do
    name =
      "quote \" backslash \\ pipe | tab \t newline \n unicode " <>
        <<0xE2, 0x9C, 0x93>> <> " percent %"

    {[row(1, "$11", name, 0, 0)], registered([1])}
  end

  defp row(id, session_id, session_name, window, index) do
    %{
      pane_id: pane(id),
      session_id: session_id,
      session_name: session_name,
      window_index: window,
      pane_index: index,
      pane_pid: id + 100,
      command: "private-input-command",
      path: "/private-input-path"
    }
  end

  defp registered(ids), do: MapSet.new(ids, &pane/1)
  defp pane(id), do: "%" <> Integer.to_string(10_000 + id)

  defp produce(request, census, registry, expected_events) do
    ref = make_ref()
    owner = self()

    opts = [
      observe: fn ->
        send(owner, {ref, :census})
        census
      end,
      registered: fn ->
        send(owner, {ref, :registry})

        case registry do
          :raise_registry -> raise "private registry diagnostic"
          result -> result
        end
      end
    ]

    candidate = Sessions.dispatch(request, opts)
    wire = Sessions.encode_reply(candidate)

    actual_events =
      Enum.map(expected_events, fn _ ->
        receive do
          {^ref, event} -> event
        after
          0 -> flunk("a required observation callback did not run")
        end
      end)

    assert actual_events == expected_events
    refute_received {^ref, _}, "extra observation or retry"
    assert RouteGuard.violations() == []
    %{candidate: candidate, wire: wire, decoded: Jason.decode!(wire)}
  end

  defp assert_empty_positive_witness do
    result = produce(@request, {:ok, []}, MapSet.new(), [:census, :registry])
    assert result.decoded == fixture("sessions.ok.empty.json")
  end

  # Only documented pane placeholders move; session names and all other data stay exact.
  defp normalize_panes(%{"sessions" => sessions} = reply) do
    placeholders = Map.new(1..8, fn id -> {pane(id), "<pane_id_#{id}>"} end)

    normalized =
      Enum.map(sessions, fn session ->
        Map.update!(session, "panes", fn addresses ->
          Enum.map(addresses, fn address ->
            Map.update!(address, "pane_id", &Map.fetch!(placeholders, &1))
          end)
        end)
      end)

    %{reply | "sessions" => normalized}
  end

  defp fixture(name), do: @fixture_dir |> Path.join(name) |> File.read!() |> Jason.decode!()
end
