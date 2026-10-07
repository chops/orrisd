defmodule AiPair.AdmissionRedTest.ManualTimer do
  @moduledoc false
  # A timer that never fires by itself: each arm is reported to the test process, which
  # delivers the timeout message explicitly (RB-3a producer scope r3, row A3).
  def arm(dest, ms, message) do
    ref = make_ref()
    send(:persistent_term.get({__MODULE__, :test}), {:armed, ref, dest, ms, message})
    ref
  end

  def cancel(_ref), do: :ok
end

defmodule AiPair.AdmissionRedTest do
  @moduledoc """
  NS-32.M.002 RB-3a RED, rows A1 to A5 (producer RED scope r3, D/rb/RB3A-PRODUCER-RED-SCOPE-r3.org,
  033d5b1e; vendored ipc-v3.org "Quiesce"). AiPair.Admission is the single linearization point:
  every mutating entry takes a ticket; quiesce closes admission, waits until no ticket is
  outstanding (or the bound), and holds one owner-bound fence until resume with the secret.

  The API these rows pin (GREEN implements it; every call goes through apply/3 because the
  module is absent at RED):

    * start_link(opts): :bound_ms, :timer (a module with arm/3 and cancel/1; production
      Process.send_after), :observe (a 0-arity function returning {:ok, observation} or
      {:error, dimension});
    * default_bound_ms/0 is the configured production default, 30_000;
    * enter(server, kind) :: {:ok, ticket} | {:error, :quiescing}, kind one of :ipc_send,
      :attach_pane, :detach_pane, :release, :idle_paste, :restore_submit; exit(server, ticket) :: :ok;
    * quiesce(server, resume_hash) :: {:ok, %{fence_id: binary, observation: map}} |
      {:error, :quiesce_busy | {:quiesce_timeout, bound_ms} | {:observation_incomplete, dim} |
      :invalid_request};
    * resume(server, fence_id, resume_secret) :: :ok | {:error, :fence_mismatch};
    * fence(server) :: nil | fence_id.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AiPair.AdmissionRedTest.ManualTimer

  @observation %{
    "receipts" => %{"versions" => [3], "queued" => 0, "pending" => 0},
    "pane_intent" => %{"version" => "2.0", "live_panes" => 0},
    "effects" => %{"version" => 1, "unresolved_holds" => 0},
    "lineage" => %{"version" => 1, "attested" => true},
    "payloads" => %{"layouts" => []},
    "session_marker" => %{"version" => 1}
  }
  # a deadlock guard only; no oracle below depends on a duration
  @guard_ms 5_000

  setup do
    :persistent_term.put({ManualTimer, :test}, self())
    on_exit(fn -> :persistent_term.erase({ManualTimer, :test}) end)
    secret = :crypto.strong_rand_bytes(32)
    secret_hex = Base.encode16(secret, case: :lower)
    hash = "sha256:" <> Base.encode16(:crypto.hash(:sha256, secret), case: :lower)
    {:ok, secret_hex: secret_hex, hash: hash}
  end

  defp start(opts \\ []) do
    defaults = [bound_ms: 1_000, timer: ManualTimer, observe: fn -> {:ok, @observation} end]
    {:ok, pid} = apply(AiPair.Admission, :start_link, [Keyword.merge(defaults, opts)])
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp call(fun, args), do: apply(AiPair.Admission, fun, args)

  defp quiesce_async(server, hash), do: Task.async(fn -> call(:quiesce, [server, hash]) end)

  test "A1 a ticket is taken and released, and quiesce defers its reply until no ticket is outstanding",
       c do
    server = start()
    assert {:ok, ticket} = call(:enter, [server, :ipc_send])
    task = quiesce_async(server, c.hash)

    assert_receive {:armed, _ref, _dest, 1_000, _message}, @guard_ms
    assert Task.yield(task, 0) == nil
    assert call(:exit, [server, ticket]) == :ok

    assert {:ok, %{fence_id: fence_id, observation: @observation}} = Task.await(task, @guard_ms)
    assert fence_id =~ ~r/\Afence_[0-9a-f]{32}\z/
    assert call(:fence, [server]) == fence_id
  end

  test "A2 after quiesce every enter is refused quiescing", c do
    server = start()
    assert {:ok, %{fence_id: _}} = call(:quiesce, [server, c.hash])

    for kind <- [:ipc_send, :attach_pane, :detach_pane, :release, :idle_paste, :restore_submit] do
      assert call(:enter, [server, kind]) == {:error, :quiescing}, inspect(kind)
    end
  end

  test "A3 the drain bound under an explicit timeout trigger: quiesce_timeout, admission reopens, no fence",
       c do
    server = start(bound_ms: 1_234)
    assert {:ok, held} = call(:enter, [server, :ipc_send])
    task = quiesce_async(server, c.hash)

    assert_receive {:armed, _ref, dest, 1_234, message}, @guard_ms
    assert Task.yield(task, 0) == nil
    send(dest, message)

    assert Task.await(task, @guard_ms) == {:error, {:quiesce_timeout, 1_234}}
    assert call(:fence, [server]) == nil
    assert {:ok, other} = call(:enter, [server, :ipc_send])
    assert call(:exit, [server, other]) == :ok
    # the held ticket is released only after the timeout was observed
    assert call(:exit, [server, held]) == :ok
  end

  test "A3 the production drain bound is 30 s by configuration, never by waiting" do
    assert call(:default_bound_ms, []) == 30_000
  end

  test "A4 a second quiesce is answered quiesce_busy promptly while the first still drains", c do
    server = start()
    assert {:ok, ticket} = call(:enter, [server, :ipc_send])
    first = quiesce_async(server, c.hash)
    assert_receive {:armed, _ref, _dest, _ms, _message}, @guard_ms

    assert call(:quiesce, [server, c.hash]) == {:error, :quiesce_busy}
    assert Task.yield(first, 0) == nil
    assert call(:exit, [server, ticket]) == :ok
    assert {:ok, %{fence_id: fence_id}} = Task.await(first, @guard_ms)

    assert call(:quiesce, [server, c.hash]) == {:error, :quiesce_busy}
    assert call(:fence, [server]) == fence_id
  end

  test "A4 of two racing quiesce calls exactly one obtains the fence", c do
    server = start()

    results =
      Task.await_many([quiesce_async(server, c.hash), quiesce_async(server, c.hash)], @guard_ms)

    assert Enum.count(results, &match?({:ok, %{fence_id: _}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :quiesce_busy})) == 1
  end

  test "A5 resume needs the fence id and the secret; every mismatch keeps the fence", c do
    server = start()
    assert {:ok, %{fence_id: fence_id}} = call(:quiesce, [server, c.hash])
    wrong_secret = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    wrong_id = "fence_" <> String.duplicate("0", 32)

    for {id, secret} <- [{wrong_id, c.secret_hex}, {fence_id, wrong_secret}, {fence_id, "zz"}] do
      assert call(:resume, [server, id, secret]) == {:error, :fence_mismatch}
      assert call(:fence, [server]) == fence_id
      assert call(:enter, [server, :ipc_send]) == {:error, :quiescing}
    end

    assert call(:resume, [server, fence_id, c.secret_hex]) == :ok
    assert call(:fence, [server]) == nil
    assert {:ok, _ticket} = call(:enter, [server, :ipc_send])
    # stale: the fence no longer exists
    assert call(:resume, [server, fence_id, c.secret_hex]) == {:error, :fence_mismatch}
  end

  test "A5 a malformed resume hash is invalid_request and changes nothing" do
    server = start()

    for hash <- [
          nil,
          "",
          "sha256:",
          "sha256:" <> String.duplicate("A", 64),
          String.duplicate("a", 64)
        ] do
      assert call(:quiesce, [server, hash]) == {:error, :invalid_request}, inspect(hash)
      assert call(:fence, [server]) == nil
    end
  end

  test "A5 neither the digest nor the secret appears in any reply, fence id or log line", c do
    server = start()

    log =
      capture_log(fn ->
        assert {:ok, %{fence_id: fence_id} = reply} = call(:quiesce, [server, c.hash])
        refute inspect(reply) =~ c.hash
        refute fence_id =~ String.replace_prefix(c.hash, "sha256:", "")
        assert call(:resume, [server, fence_id, c.secret_hex]) == :ok
      end)

    refute log =~ String.replace_prefix(c.hash, "sha256:", "")
    refute log =~ c.secret_hex
  end
end
