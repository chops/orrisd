defmodule AiPair.Delivery.PayloadStoreCapacityTest do
  @moduledoc """
  NS-15.G.003 S1 GREEN (source r1 AMEND): capacity accounting after filesystem faults.

  When a cleanup or post-link step fails, an entry the store's counts do not describe may
  remain, so the store must not claim free capacity. It disables itself: every later queue is
  refused payload_store_unavailable and finalized not_delivered, and the leftover entry stays
  until the next boot's rescan removes it, after which a queue succeeds again.

  Rows: K1 release unlink, K2 release dir_sync, K3 boot cleanup unlink, K4 boot cleanup
  dir_sync, K5 post-link temp unlink, K6 post-link dir_sync, K7 temp cleanup after a failed
  write, K8 control (a refused final name with a clean temp removal keeps the store usable).
  """

  use ExUnit.Case, async: true

  alias AiPair.Delivery.{Payload, ReceiptStore, SystemFs}
  alias AiPair.Test.FaultFs

  @pane "%payloadstore_cap"

  setup do
    inbox = Path.join(System.tmp_dir!(), "payloadstore_cap_#{System.unique_integer([:positive])}")
    File.mkdir_p!(inbox)
    on_exit(fn -> File.rm_rf!(inbox) end)
    {:ok, inbox: inbox}
  end

  for {row, op} <- [{"K1", :unlink}, {"K2", :dir_sync}] do
    test "#{row} a release #{op} failure keeps the object counted and refuses the next queue", c do
      fs = FaultFs.new()
      store = start_store!(c.inbox, fs)
      text = "#{unquote(row)} released bytes"
      {id, token} = admit!(store, "#{unquote(row)}-released", text)
      assert :ok = queue(store, id, token, text)
      FaultFs.inject(fs, unquote(op), FaultFs.count(fs, unquote(op)) + 1, {:error, :eio})

      assert :ok = ReceiptStore.transition(store, id, token, "ambiguous")
      assert last_status(c.inbox, id) == {"ambiguous", 1}

      refused_next_queue!(store, c.inbox, "#{unquote(row)}-next")
      stop(store)
      rescanned_and_usable!(c.inbox, "#{unquote(row)}-after")
    end
  end

  test "K3 a boot cleanup unlink failure leaves the store refusing queues", c do
    orphan = seed_orphan!(c.inbox, "k3-orphan")
    fs = FaultFs.new()
    FaultFs.inject(fs, :unlink, fn [path] -> path == orphan end, {:error, :eio})
    store = start_store!(c.inbox, fs)

    assert File.exists?(orphan)
    refused_next_queue!(store, c.inbox, "k3-next")
    stop(store)
    rescanned_and_usable!(c.inbox, "k3-after")
  end

  test "K4 a boot cleanup dir_sync failure leaves the store refusing queues", c do
    seed_orphan!(c.inbox, "k4-orphan")
    sync_target = Path.join(payload_dir(c.inbox), ".")
    fs = FaultFs.new()
    FaultFs.inject(fs, :dir_sync, fn [path] -> path == sync_target end, {:error, :eio})
    store = start_store!(c.inbox, fs)

    refused_next_queue!(store, c.inbox, "k4-next")
    stop(store)
    rescanned_and_usable!(c.inbox, "k4-after")
  end

  for {row, op} <- [{"K5", :unlink}, {"K6", :dir_sync}] do
    test "#{row} a post-link #{op} failure leaves an uncounted object and refuses the next queue",
         c do
      fs = FaultFs.new()
      store = start_store!(c.inbox, fs)
      text = "#{unquote(row)} linked bytes"
      {id, token} = admit!(store, "#{unquote(row)}-linked", text)
      FaultFs.inject(fs, unquote(op), FaultFs.count(fs, unquote(op)) + 1, {:error, :eio})

      assert queue(store, id, token, text) == {:error, :payload_store_unavailable}
      assert last_status(c.inbox, id) == {"not_delivered", 1}
      assert File.exists?(object_path(c.inbox, id, 1, text)), "the link succeeded"

      refused_next_queue!(store, c.inbox, "#{unquote(row)}-next")
      stop(store)
      rescanned_and_usable!(c.inbox, "#{unquote(row)}-after")
    end
  end

  test "K7 a temp that cannot be removed after a failed write refuses the next queue", c do
    fs = FaultFs.new()
    store = start_store!(c.inbox, fs)
    {id, token} = admit!(store, "k7-temp", "k7 temp bytes")
    FaultFs.inject(fs, :write, FaultFs.count(fs, :write) + 1, {:error, :eio})
    FaultFs.inject(fs, :unlink, FaultFs.count(fs, :unlink) + 1, {:error, :eio})

    assert queue(store, id, token, "k7 temp bytes") == {:error, :payload_store_unavailable}
    assert last_status(c.inbox, id) == {"not_delivered", 1}
    assert [".tmp-" <> _] = payload_entries(c.inbox)

    refused_next_queue!(store, c.inbox, "k7-next")
    stop(store)
    rescanned_and_usable!(c.inbox, "k7-after")
  end

  test "K8 control: a refused final name whose temp is removed keeps the store usable", c do
    store = start_store!(c.inbox, SystemFs.new())
    {id, token} = admit!(store, "k8-other", "k8 real bytes")
    other = object_path(c.inbox, id, 1, "k8 real bytes")
    File.mkdir_p!(payload_dir(c.inbox))
    File.write!(other, "different bytes")
    File.chmod!(other, 0o600)

    assert queue(store, id, token, "k8 real bytes") == {:error, :payload_store_unavailable}
    assert payload_entries(c.inbox) == [Path.basename(other)]

    {id2, t2} = admit!(store, "k8-next", "k8 next bytes")
    assert :ok = queue(store, id2, t2, "k8 next bytes")
    stop(store)
  end

  # ----- helpers -----

  defp refused_next_queue!(store, inbox, seed) do
    text = seed <> " bytes"
    {id, token} = admit!(store, seed, text)
    before = payload_entries(inbox)

    assert queue(store, id, token, text) == {:error, :payload_store_unavailable},
           "a store that cannot prove its capacity refuses further publications"

    assert last_status(inbox, id) == {"not_delivered", 1}
    assert payload_entries(inbox) == before
  end

  defp rescanned_and_usable!(inbox, seed) do
    restarted = start_store!(inbox, SystemFs.new())
    assert payload_entries(inbox) == []
    {id, token} = admit!(restarted, seed, seed <> " bytes")
    assert :ok = queue(restarted, id, token, seed <> " bytes")
    stop(restarted)
  end

  defp seed_orphan!(inbox, seed) do
    store = start_store!(inbox, SystemFs.new())
    stop(store)
    orphan = object_path(inbox, id(seed), 1, seed <> " bytes")
    File.write!(orphan, seed <> " bytes")
    File.chmod!(orphan, 0o600)
    orphan
  end

  defp queue(store, id, token, text), do: ReceiptStore.queue(store, id, token, text)

  defp start_store!(inbox, fs) do
    assert {:ok, pid} = GenServer.start(ReceiptStore, inbox: inbox, fs: fs)
    pid
  end

  defp stop(pid), do: if(Process.alive?(pid), do: Process.exit(pid, :kill))

  defp admit!(store, seed, text) do
    msg_id = id(seed)

    assert {:ok, {:admitted, %{operation_token: token}}} =
             ReceiptStore.admit(store, msg_id, @pane, hash(text), self())

    {msg_id, token}
  end

  defp payload_dir(inbox), do: Path.join([inbox, "delivery", "payloads"])

  defp object_path(inbox, msg_id, attempt, text) do
    "sha256:" <> hex = hash(text)
    Path.join(payload_dir(inbox), "#{msg_id}.#{attempt}.#{hex}.payload")
  end

  defp payload_entries(inbox) do
    case File.ls(payload_dir(inbox)) do
      {:ok, names} -> Enum.sort(names)
      {:error, :enoent} -> []
    end
  end

  defp last_status(inbox, msg_id) do
    [inbox, "delivery", "receipts.jsonl"]
    |> Path.join()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["message_id"] == msg_id))
    |> Enum.map(&{&1["status"], &1["delivery_attempt"]})
    |> List.last()
  end

  defp hash(text), do: Payload.hash(Payload.new(text))

  defp id(seed), do: "snd_" <> Base.encode16(:crypto.hash(:sha256, seed), case: :lower)
end
