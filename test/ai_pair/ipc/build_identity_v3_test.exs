defmodule AiPair.IPC.BuildIdentityV3Test do
  @moduledoc """
  NS-32.M.001 RB-1: the build identity a release records and the version 3 ping that reports it
  (vendored `docs/contracts/ipc-v3.org`, the RB-1K `build_identity` token and object).

  A release carries `share/ai-pair/build-identity.json`, the eight-key record. It is read once with
  `AiPair.BuildIdentity.read/1`, which returns the record exactly or refuses it:
  `{:error, :absent}` when there is no file, and another error for a record that is not exactly
  eight keys of the contract's types, or whose `rollback_eligible` is not exactly "clean and a
  40-hex source revision". The ping reports a read record as `build_identity`, with the token. It
  reports nothing, and no token, when no record was read.

  Both build pings (clean and dirty) are produced here through the real dispatch path. Since the
  RB-1 reciprocal pairing (orris f01631a7) the clean one is also a claimed core reply, produced in
  contract_v3_fixture_test.exs; the dirty one stays an example.
  """

  use ExUnit.Case, async: false

  alias AiPair.Delivery.ReceiptStore

  @root Path.expand("../../fixtures/contracts/ipc/v3", __DIR__)
  @keys ~w(build_id clean ipc_protocols name rollback_eligible source_nar_hash source_revision version)

  setup do
    suffix = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "build-identity-v3-#{suffix}")
    inbox = Path.join(dir, "inbox")
    release = Path.join(dir, "release")
    File.mkdir_p!(inbox)
    File.mkdir_p!(Path.join(release, "share/ai-pair"))
    on_exit(fn -> File.rm_rf!(dir) end)

    store = start_supervised!({ReceiptStore, [inbox: inbox]})
    {:ok, store: store, release: release, pane: "%build_identity_#{suffix}"}
  end

  for name <-
        ~w(ping.ok.identity_core_release_build.json ping.ok.identity_core_release_build_dirty.json) do
    test "a release's identity record is read exactly and the ping reports it: #{name}", c do
      expected = fixture(unquote(name))
      write_record(c, Jason.encode!(expected["build_identity"]))

      {:ok, identity} = read(c.release)
      assert identity == expected["build_identity"]

      reply = v3_dispatch(%{"cmd" => "ping", "protocol_version" => 3}, context(c, identity))
      assert normalized(reply) == expected
    end
  end

  # Independent of the reader: the ping reports the record it is given, token and object together.
  for name <-
        ~w(ping.ok.identity_core_release_build.json ping.ok.identity_core_release_build_dirty.json) do
    test "the ping reports the record in its context exactly: #{name}", c do
      expected = fixture(unquote(name))
      context = context(c, expected["build_identity"])

      reply = v3_dispatch(%{"cmd" => "ping", "protocol_version" => 3}, context)
      assert normalized(reply) == expected
    end
  end

  test "a release without a record reads :absent and its ping has neither token nor object", c do
    assert read(c.release) == {:error, :absent}

    reply = v3_dispatch(%{"cmd" => "ping", "protocol_version" => 3}, context(c, nil))
    refute "build_identity" in reply.capabilities
    refute Map.has_key?(reply, :build_identity)
    assert normalized(reply) == fixture("ping.ok.identity_core_release.json")
  end

  test "a record that is not exactly the contract's eight typed keys is refused", c do
    valid = fixture("ping.ok.identity_core_release_build.json")["build_identity"]

    cases = [
      {"not JSON", "{\"name\": "},
      {"not an object", Jason.encode!([valid])},
      {"an extra key", Jason.encode!(Map.put(valid, "built_at", "2026-10-07"))},
      {"a missing key", Jason.encode!(Map.delete(valid, "build_id"))},
      {"clean not a boolean", Jason.encode!(Map.put(valid, "clean", "true"))},
      {"build_id not 64 lowercase hex",
       Jason.encode!(Map.put(valid, "build_id", String.upcase(valid["build_id"])))},
      {"source_revision a sentinel", Jason.encode!(Map.put(valid, "source_revision", "unknown"))},
      {"ipc_protocols not integers", Jason.encode!(Map.put(valid, "ipc_protocols", ["3"]))},
      {"name not a string", Jason.encode!(Map.put(valid, "name", nil))},
      {"version not a string", Jason.encode!(Map.put(valid, "version", 1))},
      {"source_revision uppercase hex",
       Jason.encode!(Map.put(valid, "source_revision", String.upcase(valid["source_revision"])))},
      {"source_revision 39 hex",
       Jason.encode!(
         Map.put(valid, "source_revision", String.slice(valid["source_revision"], 1..-1//1))
       )},
      {"source_revision not a string", Jason.encode!(Map.put(valid, "source_revision", 7))},
      {"source_nar_hash without sha256-",
       Jason.encode!(Map.put(valid, "source_nar_hash", "md5-" <> valid["source_nar_hash"]))},
      {"source_nar_hash not a string", Jason.encode!(Map.put(valid, "source_nar_hash", 256))}
    ]

    for {label, bytes} <- cases do
      write_record(c, bytes)
      assert {:error, reason} = read(c.release), label
      refute reason == :absent, label
    end
  end

  test "rollback_eligible must be exactly a clean build with a 40-hex source revision", c do
    clean = fixture("ping.ok.identity_core_release_build.json")["build_identity"]
    dirty = fixture("ping.ok.identity_core_release_build_dirty.json")["build_identity"]

    for {label, record} <- [
          {"eligible while dirty", Map.put(dirty, "rollback_eligible", true)},
          {"eligible without a revision", %{clean | "source_revision" => nil}},
          {"ineligible while clean with a revision", %{clean | "rollback_eligible" => false}},
          {"eligibility not a boolean", %{clean | "rollback_eligible" => "true"}}
        ] do
      write_record(c, Jason.encode!(record))
      assert {:error, reason} = read(c.release), label
      refute reason == :absent, label
    end
  end

  test "a build identity in the context changes no reply but the ping", c do
    identity = fixture("ping.ok.identity_core_release_build.json")["build_identity"]
    assert identity |> Map.keys() |> Enum.sort() == @keys
    request = %{"cmd" => "status", "protocol_version" => 3, "pane_id" => c.pane}

    reply = v3_dispatch(request, context(c, identity))
    refute Map.has_key?(reply, :build_identity)
    assert reply == v3_dispatch(request, context(c, nil))
  end

  # apply/3: AiPair.BuildIdentity is GREEN's module, absent at the RED base.
  defp read(release), do: apply(AiPair.BuildIdentity, :read, [release])

  defp v3_dispatch(request, context), do: AiPair.IPC.DeliveryV3.dispatch(request, context)

  defp write_record(c, bytes),
    do: File.write!(Path.join(c.release, "share/ai-pair/build-identity.json"), bytes)

  defp context(c, identity) do
    %{
      receipt_store: c.store,
      durable: true,
      committed: fn _pane -> :none end,
      current_pid: fn _pane -> :error end,
      build_identity: identity
    }
  end

  defp fixture(name), do: @root |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp normalized(reply) do
    reply = reply |> Jason.encode!() |> Jason.decode!()
    if reply["pong"] == AiPair.version(), do: Map.put(reply, "pong", "<version>"), else: reply
  end
end
