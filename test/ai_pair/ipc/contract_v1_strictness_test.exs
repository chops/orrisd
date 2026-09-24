defmodule AiPair.IPC.ContractV1StrictnessTest do
  @moduledoc """
  NS-39.A.001: the IPC v1 reply contract, checked strictly.

  `contract_fixture_test.exs` replaces every varying v1 field with its placeholder
  string before comparing, so the TYPE and FORMAT of those fields are never checked:
  a `pane_status` reply carrying `"state" => 42` or `"pending_count" => "0"` would
  still compare equal. It also proves the `msg_id` non-echo rule on the `sent` reply
  only, and `server_test.exs` checks `queue_reason` membership only for whichever reason
  one run happens to produce.

  The contract text these rows read is `docs/contracts/ipc-v1.org`, "Framing and version":

    * `<version>` is the running ai-pair version;
    * `pane_status.state` is one of `idle`, `busy`, `dialog`, `dead`, `unknown`;
    * `pane_status.agent` is a registered agent string or `null`;
    * `pane_status.classifier` is a classifier name string;
    * `pane_status.pending_count` is a non-negative integer, the fixture's `0` being
      representative;
    * a queued send has `queue_reason` equal to `debounce`, `busy`, `dialog` or `unknown`;
    * a `send` request may carry `msg_id`, which is not echoed in a v1 reply.

  Nothing in product code is changed; every row asserts behaviour that is present.
  """

  # One row changes the send-call timeout in the application environment.
  use ExUnit.Case, async: false

  alias AiPair.Pane.StateMachine
  alias AiPair.Test.ReceiptBackedIPCServer, as: Server

  @fixture_dir Path.expand("../../fixtures/contracts/ipc/v1", __DIR__)
  @contract_doc Path.expand("../../../docs/contracts/ipc-v1.org", __DIR__)

  @states ~w(idle busy dialog dead unknown)
  @queue_reasons ~w(debounce busy dialog unknown)

  @state_lead "- ~pane_status.state~ is one of"
  @queue_reason_lead "- A queued send has ~queue_reason~ equal to"

  # Every v1 reply kind in the fixture table, with the request that produces it.
  @kinds [
    :ping,
    :status_ok,
    :status_unowned,
    :status_missing_pane_id,
    :status_not_found,
    :status_dead,
    :sent,
    :queued,
    :queue_full,
    :missing_pane_id,
    :missing_text,
    :oversize,
    :not_found,
    :pane_dead,
    :send_timeout,
    :paste_failed
  ]

  setup do
    tmp = Path.join(System.tmp_dir!(), "ai_pair_ipc_strict_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "sock"))
    File.chmod!(Path.join(tmp, "sock"), 0o700)
    sock_path = Path.join(tmp, "sock/ai-pair.sock")

    {:ok, server} = Server.start_link(inbox: tmp, name: :ipc_contract_v1_strictness_server)

    # The listener socket is disposable and uniquely named; cleanup is asserted, so a
    # row that leaves the server or its socket behind fails even if its body passed.
    on_exit(fn ->
      stop_quietly(server)
      File.rm_rf!(tmp)
      refute Process.alive?(server), "the IPC listener outlived its test"
      refute File.exists?(sock_path), "the IPC socket outlived its test"
    end)

    %{sock_path: sock_path}
  end

  describe "varying v1 fields are typed, not only replaced" do
    test "the vocabularies these rows use are the ones the contract states" do
      assert contract_vocabulary(@state_lead) == @states
      assert contract_vocabulary(@queue_reason_lead) == @queue_reasons
    end

    test "every v1 reply kind carries correctly typed varying fields", %{sock_path: sock_path} do
      # Every fixture in the pinned directory is exercised by at least one kind.
      covered = @kinds |> Enum.map(&fixture_name/1) |> Enum.uniq() |> Enum.sort()
      pinned = @fixture_dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".json"))
      assert covered == Enum.sort(pinned)

      for kind <- @kinds do
        {raw, bindings} = drive(kind, sock_path, %{})
        conform!(raw, fixture_name(kind), bindings)
      end
    end

    test "pending_count is the live queue depth, not the fixture's constant",
         %{sock_path: sock_path} do
      {raw, bindings} = drive(:status_ok, sock_path, %{})
      reply = conform!(raw, "pane_status.ok.json", bindings)

      assert reply["pending_count"] == 3,
             "the fixture's 0 is representative; a reply pinned to 0 would hide the queue"
    end

    test "control: each out-of-contract value is rejected by the same check" do
      pane_id = unique_pane("control")

      status = %{
        pane_id: pane_id,
        state: "busy",
        agent: "claude_code",
        classifier: "fixture",
        pending_count: 3
      }

      good_status = %{
        "agent" => "claude_code",
        "classifier" => "fixture",
        "ok" => true,
        "pane_id" => pane_id,
        "pending_count" => 3,
        "state" => "busy"
      }

      # The well-formed reply passes, so each rejection below is the edited field alone.
      conform!(Jason.encode!(good_status), "pane_status.ok.json", status)

      status_violations = [
        {"state", "sleeping"},
        {"state", 42},
        {"agent", 42},
        {"classifier", ""},
        {"classifier", nil},
        {"pending_count", -1},
        {"pending_count", "3"},
        {"pending_count", 3.0},
        {"pane_id", unique_pane("someone-else")}
      ]

      for {key, bad} <- status_violations do
        refuse!(Map.put(good_status, key, bad), "pane_status.ok.json", status)
      end

      refuse!(Map.put(good_status, "quarantined", false), "pane_status.ok.json", status)

      for bad <- [1, "", "not a version"] do
        refuse!(%{"ok" => true, "pong" => bad}, "ping.ok.json", %{})
      end

      failed = %{"ok" => false, "error" => "paste_failed", "pane_id" => pane_id}
      paste = %{pane_id: pane_id}

      for bad <- [42, "", nil] do
        refuse!(Map.put(failed, "detail", bad), "send.error.paste_failed.json", paste)
      end

      queued = %{"ok" => true, "pane_id" => pane_id, "status" => "queued"}
      bindings = %{pane_id: pane_id, queue_reason: "busy"}

      for bad <- ["stalled", "idle", "dead", 7, nil] do
        refuse!(Map.put(queued, "queue_reason", bad), "send.queued.json", bindings)
      end
    end
  end

  describe "msg_id is never echoed in a v1 reply" do
    test "no v1 reply kind carries the request's msg_id", %{sock_path: sock_path} do
      for kind <- @kinds do
        msg_id = "msg_ns39_#{kind}_#{System.unique_integer([:positive])}"
        {raw, bindings} = drive(kind, sock_path, %{"msg_id" => msg_id})

        # The reply is the kind it claims to be, so the non-echo is asserted per kind.
        conform!(raw, fixture_name(kind), bindings)
        refute_echo!(raw, msg_id)
      end
    end

    test "control: the non-echo check fails on a reply that echoes msg_id" do
      msg_id = "msg_ns39_control"
      sent = fixture("send.sent.json")

      assert_raise ExUnit.AssertionError, fn ->
        refute_echo!(Jason.encode!(Map.put(sent, "msg_id", msg_id)), msg_id)
      end

      assert_raise ExUnit.AssertionError, fn ->
        refute_echo!(Jason.encode!(Map.put(sent, "detail", msg_id)), msg_id)
      end
    end
  end

  describe "the queue-reason vocabulary is closed" do
    test "every pane state is driven and the server emits only contract reasons",
         %{sock_path: sock_path} do
      # The pane state space is read from the product's own type, so a sixth state
      # would enter this enumeration rather than escape it.
      states = pane_states()
      assert Enum.sort(states) == @states |> Enum.map(&String.to_atom/1) |> Enum.sort()

      replies =
        for state <- states do
          {state, send_in_state(sock_path, state)}
        end

      for {state, {raw, bindings}} <- replies do
        reply = Jason.decode!(raw)

        case reply do
          %{"status" => "queued"} ->
            assert reply["queue_reason"] in @queue_reasons,
                   "#{state}: #{inspect(reply["queue_reason"])} is outside the contract"

            conform!(raw, "send.queued.json", bindings)

          %{"error" => "pane_dead"} ->
            assert state == :dead
            conform!(raw, "send.error.pane_dead.json", bindings)
        end
      end

      emitted =
        replies
        |> Enum.map(fn {_state, {raw, _bindings}} -> reason(raw) end)
        |> Enum.reject(&is_nil/1)

      assert Enum.sort(emitted) == Enum.sort(@queue_reasons),
             "each contract reason is produced exactly once across the pane state space"

      reasons = Map.new(replies, fn {state, {raw, _bindings}} -> {state, reason(raw)} end)

      assert reasons == %{
               idle: "debounce",
               busy: "busy",
               dialog: "dialog",
               unknown: "unknown",
               dead: nil
             }
    end

    test "an idle pane past its debounce sends and carries no queue reason",
         %{sock_path: sock_path} do
      {raw, bindings} = drive(:sent, sock_path, %{})
      reply = conform!(raw, "send.sent.json", bindings)
      refute Map.has_key?(reply, "queue_reason")
    end
  end

  # ===== drivers: one per v1 reply kind =====

  defp fixture_name(:ping), do: "ping.ok.json"
  defp fixture_name(:status_ok), do: "pane_status.ok.json"
  defp fixture_name(:status_unowned), do: "pane_status.ok.json"
  defp fixture_name(:status_missing_pane_id), do: "pane_status.error.missing_pane_id.json"
  defp fixture_name(:status_not_found), do: "pane_status.error.pane_not_found.json"
  defp fixture_name(:status_dead), do: "pane_status.error.pane_dead.json"
  defp fixture_name(:sent), do: "send.sent.json"
  defp fixture_name(:queued), do: "send.queued.json"
  defp fixture_name(:queue_full), do: "send.error.queue_full.json"
  defp fixture_name(:missing_pane_id), do: "send.error.missing_pane_id.json"
  defp fixture_name(:missing_text), do: "send.error.missing_text.json"
  defp fixture_name(:oversize), do: "send.error.oversize.json"
  defp fixture_name(:not_found), do: "send.error.pane_not_found.json"
  defp fixture_name(:pane_dead), do: "send.error.pane_dead.json"
  defp fixture_name(:send_timeout), do: "send.error.send_timeout.json"
  defp fixture_name(:paste_failed), do: "send.error.paste_failed.json"

  defp drive(:ping, sock_path, extra) do
    {request(sock_path, %{"cmd" => "ping"}, extra), %{}}
  end

  defp drive(:status_ok, sock_path, extra) do
    pane_id = unique_pane("status-ok")
    pane = start_fixture_pane(pane_id, "BUSY_MARKER", agent: "claude_code")
    wait_for_state(pane_id, :busy)

    for index <- 1..3 do
      assert {:queued, :busy} = StateMachine.send_text(pane, "pending-#{index}")
    end

    bindings = %{
      pane_id: pane_id,
      state: "busy",
      agent: "claude_code",
      classifier: "fixture",
      pending_count: 3
    }

    {request(sock_path, %{"cmd" => "pane_status", "pane_id" => pane_id}, extra), bindings}
  end

  defp drive(:status_unowned, sock_path, extra) do
    pane_id = unique_pane("status-unowned")
    start_fixture_pane(pane_id, "IDLE_MARKER")
    wait_for_state(pane_id, :idle)

    bindings = %{
      pane_id: pane_id,
      state: "idle",
      agent: nil,
      classifier: "fixture",
      pending_count: 0
    }

    {request(sock_path, %{"cmd" => "pane_status", "pane_id" => pane_id}, extra), bindings}
  end

  defp drive(:status_missing_pane_id, sock_path, extra) do
    {request(sock_path, %{"cmd" => "pane_status"}, extra), %{}}
  end

  defp drive(:status_not_found, sock_path, extra) do
    pane_id = unique_pane("status-missing")
    payload = %{"cmd" => "pane_status", "pane_id" => pane_id}
    {request(sock_path, payload, extra), %{pane_id: pane_id}}
  end

  defp drive(:status_dead, sock_path, extra) do
    pane_id = unique_pane("status-dead")
    owner = self()

    # A registered owner that dies between the lookup and the status call, as in
    # `contract_fixture_test.exs`.
    dead_owner =
      spawn(fn ->
        Registry.register(AiPair.Registry, {:pane, pane_id}, nil)
        send(owner, {:dead_status_owner_ready, pane_id})

        receive do
          {:"$gen_call", _from, :status} -> exit(:kill)
        end
      end)

    on_exit(fn -> if Process.alive?(dead_owner), do: Process.exit(dead_owner, :kill) end)
    assert_receive {:dead_status_owner_ready, ^pane_id}

    payload = %{"cmd" => "pane_status", "pane_id" => pane_id}
    {request(sock_path, payload, extra), %{pane_id: pane_id}}
  end

  defp drive(:sent, sock_path, extra) do
    pane_id = unique_pane("sent")
    start_fixture_pane(pane_id, "IDLE_MARKER")
    wait_for_state(pane_id, :idle)
    {send_text(sock_path, pane_id, "sent", extra), %{pane_id: pane_id}}
  end

  defp drive(:queued, sock_path, extra) do
    pane_id = unique_pane("queued")
    start_fixture_pane(pane_id, "BUSY_MARKER")
    wait_for_state(pane_id, :busy)
    raw = send_text(sock_path, pane_id, "queued", extra)
    {raw, %{pane_id: pane_id, queue_reason: "busy"}}
  end

  defp drive(:queue_full, sock_path, extra) do
    pane_id = unique_pane("full")
    pane = start_fixture_pane(pane_id, "BUSY_MARKER")
    wait_for_state(pane_id, :busy)

    for index <- 1..StateMachine.max_pending_sends() do
      assert {:queued, :busy} = StateMachine.send_text(pane, "fill-#{index}")
    end

    {send_text(sock_path, pane_id, "overflow", extra), %{pane_id: pane_id}}
  end

  defp drive(:missing_pane_id, sock_path, extra) do
    {request(sock_path, %{"cmd" => "send", "text" => "hello"}, extra), %{}}
  end

  defp drive(:missing_text, sock_path, extra) do
    payload = %{"cmd" => "send", "pane_id" => unique_pane("no-text")}
    {request(sock_path, payload, extra), %{}}
  end

  defp drive(:oversize, sock_path, extra) do
    pane_id = unique_pane("oversize")
    oversize = :binary.copy("x", 524_289)
    {send_text(sock_path, pane_id, oversize, extra), %{pane_id: pane_id}}
  end

  defp drive(:not_found, sock_path, extra) do
    pane_id = unique_pane("missing")
    {send_text(sock_path, pane_id, "hello", extra), %{pane_id: pane_id}}
  end

  defp drive(:pane_dead, sock_path, extra) do
    pane_id = unique_pane("dead")
    pane = start_fixture_pane(pane_id, "BUSY_MARKER")
    wait_for_state(pane_id, :busy)
    StateMachine.mark_dead(pane)
    wait_for_state(pane_id, :dead)
    {send_text(sock_path, pane_id, "hello", extra), %{pane_id: pane_id}}
  end

  defp drive(:send_timeout, sock_path, extra) do
    pane_id = unique_pane("timeout")
    slow = fn _, _ -> Process.sleep(100) && :ok end
    start_fixture_pane(pane_id, "IDLE_MARKER", paste_fn: slow)
    wait_for_state(pane_id, :idle)

    previous = Application.fetch_env(:ai_pair, :send_call_timeout_ms)
    Application.put_env(:ai_pair, :send_call_timeout_ms, 10)

    try do
      {send_text(sock_path, pane_id, "slow", extra), %{pane_id: pane_id}}
    after
      case previous do
        {:ok, value} -> Application.put_env(:ai_pair, :send_call_timeout_ms, value)
        :error -> Application.delete_env(:ai_pair, :send_call_timeout_ms)
      end
    end
  end

  defp drive(:paste_failed, sock_path, extra) do
    pane_id = unique_pane("paste-failed")
    failing = fn _, _ -> {:error, :fixture_failure} end
    start_fixture_pane(pane_id, "IDLE_MARKER", paste_fn: failing)
    wait_for_state(pane_id, :idle)
    {send_text(sock_path, pane_id, "fail", extra), %{pane_id: pane_id}}
  end

  # One v1 send against a pane held in `state`, answering the reply and its bindings.
  defp send_in_state(sock_path, state) do
    pane_id = unique_pane("state-#{state}")

    case state do
      :idle ->
        # Idle, but the debounce has not elapsed: the send is parked, not pasted.
        start_fixture_pane(pane_id, "IDLE_MARKER", idle_debounce_ms: 60_000)
        wait_for_state(pane_id, :idle)

      :busy ->
        start_fixture_pane(pane_id, "BUSY_MARKER")
        wait_for_state(pane_id, :busy)

      :dialog ->
        start_fixture_pane(pane_id, "DIALOG_MARKER")
        wait_for_state(pane_id, :dialog)

      :unknown ->
        start_fixture_pane(pane_id, "no marker in this capture")
        wait_for_state(pane_id, :unknown)

      :dead ->
        pane = start_fixture_pane(pane_id, "BUSY_MARKER")
        wait_for_state(pane_id, :busy)
        StateMachine.mark_dead(pane)
        wait_for_state(pane_id, :dead)
    end

    raw = send_text(sock_path, pane_id, "state #{state}", %{})
    bindings = %{pane_id: pane_id, queue_reason: reason(raw)}
    {raw, bindings}
  end

  defp reason(raw), do: Jason.decode!(raw)["queue_reason"]

  # ===== contract checks =====

  # Compares a reply to its fixture after checking each varying field against the
  # contract, then substituting the fixture's own value. A field the fixture fixes
  # must match exactly, and the key set is closed.
  defp conform!(raw, name, bindings) do
    reply = Jason.decode!(raw)
    expected = fixture(name)

    assert Enum.sort(Map.keys(reply)) == Enum.sort(Map.keys(expected)),
           "#{name}: the v1 reply key set is closed, got #{inspect(Map.keys(reply))}"

    normalized =
      Enum.reduce(expected, reply, fn {key, template}, acc ->
        if varying?(key, template) do
          value = Map.fetch!(reply, key)

          assert valid?(key, template, value, bindings),
                 "#{name}: #{key} = #{inspect(value)} violates the v1 contract"

          Map.put(acc, key, template)
        else
          acc
        end
      end)

    assert normalized == expected, "#{name}: the fixed fields must match the fixture"
    reply
  end

  defp refuse!(reply, name, bindings) do
    assert_raise ExUnit.AssertionError, fn -> conform!(Jason.encode!(reply), name, bindings) end
  end

  defp varying?(key, template) do
    key in ["pending_count", "queue_reason"] or placeholder?(template)
  end

  defp placeholder?(value), do: is_binary(value) and Regex.match?(~r/\A<[a-z_]+>\z/, value)

  defp valid?("pong", "<version>", value, _bindings) do
    version_format = ~r/\A\d+\.\d+\.\d+([-+][0-9A-Za-z.+-]+)?\z/
    is_binary(value) and value == AiPair.version() and Regex.match?(version_format, value)
  end

  defp valid?("pane_id", "<pane_id>", value, bindings) do
    is_binary(value) and value == Map.fetch!(bindings, :pane_id)
  end

  defp valid?("state", "<state>", value, bindings) do
    value in @states and value == Map.fetch!(bindings, :state)
  end

  defp valid?("agent", "<agent>", value, bindings) do
    (is_nil(value) or is_binary(value)) and value == Map.fetch!(bindings, :agent)
  end

  defp valid?("classifier", "<classifier>", value, bindings) do
    is_binary(value) and value != "" and value == Map.fetch!(bindings, :classifier)
  end

  defp valid?("detail", "<detail>", value, _bindings) do
    is_binary(value) and String.trim(value) != ""
  end

  defp valid?("pending_count", 0, value, bindings) do
    is_integer(value) and value >= 0 and value == Map.fetch!(bindings, :pending_count)
  end

  defp valid?("queue_reason", _representative, value, bindings) do
    value in @queue_reasons and value == Map.fetch!(bindings, :queue_reason)
  end

  defp refute_echo!(raw, msg_id) do
    reply = Jason.decode!(raw)
    refute Map.has_key?(reply, "msg_id"), "a v1 reply must not carry msg_id"

    refute String.contains?(raw, msg_id), "a v1 reply must not echo msg_id under any key"
  end

  # The words of one contract bullet that are written as ~word~, minus the subject.
  defp contract_vocabulary(lead) do
    [_before, rest] = @contract_doc |> File.read!() |> String.split(lead, parts: 2)
    [bullet | _] = String.split(rest, ~r/\n(- |\n)/, parts: 2)

    ~r/~([a-z_]+)~/
    |> Regex.scan(bullet, capture: :all_but_first)
    |> List.flatten()
  end

  defp pane_states do
    {:ok, types} = Code.Typespec.fetch_types(StateMachine)

    [members] = for {:type, {:pane_state, {:type, _, :union, members}, []}} <- types, do: members

    for {:atom, _, state} <- members, do: state
  end

  # ===== socket and pane helpers =====

  defp fixture(name) do
    @fixture_dir
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end

  defp send_text(sock_path, pane_id, text, extra) do
    request(sock_path, %{"cmd" => "send", "pane_id" => pane_id, "text" => text}, extra)
  end

  defp request(sock_path, payload, extra) do
    {:ok, client} =
      :gen_tcp.connect({:local, sock_path}, 0, [:binary, {:active, false}, {:packet, 4}], 1_000)

    try do
      :ok = :gen_tcp.send(client, Jason.encode!(Map.merge(payload, extra)))
      {:ok, frame} = :gen_tcp.recv(client, 0, 1_000)
      frame
    after
      :gen_tcp.close(client)
    end
  end

  defp stop_quietly(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _reason -> :ok
      end
    end
  end

  defp start_fixture_pane(pane_id, marker, opts \\ []) do
    on_exit(fn -> AiPair.PaneSupervisor.stop_pane(pane_id) end)

    defaults = [
      capture_fn: fn _ -> {:ok, marker} end,
      paste_fn: fn _, _ -> :ok end,
      classifier: AiPair.Test.MarkerClassifier,
      classifier_name: "fixture",
      poll_interval_ms: 5,
      idle_debounce_ms: 0
    ]

    {:ok, pane} = AiPair.PaneSupervisor.start_pane(pane_id, Keyword.merge(defaults, opts))
    pane
  end

  defp wait_for_state(pane_id, expected) do
    pane = {:via, Registry, {AiPair.Registry, {:pane, pane_id}}}
    deadline = System.monotonic_time(:millisecond) + 1_000

    Stream.repeatedly(fn -> StateMachine.state(pane) end)
    |> Enum.reduce_while(nil, fn
      ^expected, _ ->
        {:halt, :ok}

      _state, _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:halt, :timeout}
        else
          Process.sleep(5)
          {:cont, nil}
        end
    end)
    |> case do
      :ok -> :ok
      :timeout -> flunk("pane #{pane_id} did not reach #{expected}")
    end
  end

  defp unique_pane(label), do: "%strict-#{label}-#{System.unique_integer([:positive])}"
end
