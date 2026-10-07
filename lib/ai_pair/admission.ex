defmodule AiPair.Admission do
  @moduledoc """
  The single linearization point of the version 3 quiesce fence (NS-32.M.002 RB-3a; vendored
  ipc-v3.org "Quiesce"; RB-3a scope r3, D/rb/RB3A-QUIESCE-SCOPE-r3.org).

  Every path that can admit or paste a send takes a ticket with `enter/2` before its first
  mutation and returns it with `exit/2` once that mutation reached a terminal store state.
  `quiesce/2` closes admission in this process's state: every `enter/2` handled after it is
  refused `{:error, :quiescing}`. The reply is deferred until no ticket is outstanding (the
  drain) or the bound expires; after the drain the receipt store is closed
  (`ReceiptStore.close_admission/1`) and one observation is read while admission stays closed.
  On success one fence is held, bound to the digest of a secret the client keeps; `resume/3`
  with that fence id and secret reopens the store and then admission. Any mismatch is
  `{:error, :fence_mismatch}` and changes nothing. There is no expiry.

  Options: `:bound_ms` (default `default_bound_ms/0`), `:timer` (a module with `arm/3` and
  `cancel/1`; default `AiPair.Admission.Timer`, Process.send_after), `:observe` (a 0-arity
  function returning `{:ok, observation}` or `{:error, dimension}`), `:receipt_store` (closed
  after the drain and reopened on resume; optional), `:name`.
  """

  use GenServer

  @default_bound_ms 30_000
  @kinds [:ipc_send, :attach_pane, :detach_pane, :release, :idle_paste, :restore_submit]
  @hash ~r/\Asha256:[0-9a-f]{64}\z/
  @secret ~r/\A[0-9a-f]{64}\z/

  @spec default_bound_ms() :: pos_integer()
  def default_bound_ms, do: Application.get_env(:ai_pair, :quiesce_bound_ms, @default_bound_ms)

  def start_link(opts) when is_list(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts)
    end
  end

  @spec enter(GenServer.server(), atom()) :: {:ok, reference()} | {:error, :quiescing}
  def enter(server, kind) when kind in @kinds, do: GenServer.call(server, {:enter, kind})

  @spec exit(GenServer.server(), reference()) :: :ok
  def exit(server, ticket), do: GenServer.call(server, {:exit, ticket})

  def quiesce(server, resume_hash), do: GenServer.call(server, {:quiesce, resume_hash}, :infinity)

  def resume(server, fence_id, secret), do: GenServer.call(server, {:resume, fence_id, secret})

  @doc """
  Run `fun` under a ticket of kind `kind`: `{:ok, fun.()}`, or `{:error, :quiescing}` without
  calling `fun` while a fence is held or a quiesce drains. The ticket is returned when `fun`
  returns or raises. A nil server (no admission configured) runs `fun` directly.
  """
  def run(nil, _kind, fun), do: {:ok, fun.()}

  def run(server, kind, fun) do
    case enter(server, kind) do
      {:ok, ticket} ->
        try do
          {:ok, fun.()}
        after
          __MODULE__.exit(server, ticket)
        end

      {:error, :quiescing} = refused ->
        refused
    end
  end

  @doc """
  The StateMachine start options that bind a pane child to `admission` (none when nil): every
  path that starts a pane child (v1 attach, durable attach, release, boot reconciliation) adds
  these, so each of its queued pastes takes an :idle_paste ticket.
  """
  def child_opts(nil), do: []
  def child_opts(admission), do: [admission: admission]

  @spec fence(GenServer.server()) :: String.t() | nil
  def fence(server), do: GenServer.call(server, :fence)

  @impl true
  def init(opts) do
    {:ok,
     %{
       bound_ms: Keyword.get(opts, :bound_ms, default_bound_ms()),
       timer: Keyword.get(opts, :timer, AiPair.Admission.Timer),
       observe: Keyword.get(opts, :observe, fn -> {:error, "receipts"} end),
       store: Keyword.get(opts, :receipt_store),
       tickets: %{},
       # :open | {:draining, from, digest, timer_ref, token} | {:fenced, fence_id, digest}
       mode: :open
     }}
  end

  @impl true
  def handle_call({:enter, _kind}, _from, %{mode: :open} = state) do
    ticket = make_ref()
    {:reply, {:ok, ticket}, %{state | tickets: Map.put(state.tickets, ticket, true)}}
  end

  def handle_call({:enter, _kind}, _from, state), do: {:reply, {:error, :quiescing}, state}

  def handle_call({:exit, ticket}, _from, state) do
    state = %{state | tickets: Map.delete(state.tickets, ticket)}
    {:reply, :ok, maybe_complete(state)}
  end

  def handle_call({:quiesce, hash}, from, %{mode: :open} = state) do
    if is_binary(hash) and Regex.match?(@hash, hash) do
      token = make_ref()
      timer = state.timer.arm(self(), state.bound_ms, {:drain_bound, token})
      state = %{state | mode: {:draining, from, hash, timer, token}}
      {:noreply, maybe_complete(state)}
    else
      {:reply, {:error, :invalid_request}, state}
    end
  end

  def handle_call({:quiesce, hash}, _from, state) do
    if is_binary(hash) and Regex.match?(@hash, hash),
      do: {:reply, {:error, :quiesce_busy}, state},
      else: {:reply, {:error, :invalid_request}, state}
  end

  def handle_call({:resume, fence_id, secret}, _from, %{mode: {:fenced, fence_id, digest}} = state)
      when is_binary(secret) do
    with true <- Regex.match?(@secret, secret),
         {:ok, bytes} <- Base.decode16(secret, case: :lower),
         true <- "sha256:" <> hex(:crypto.hash(:sha256, bytes)) == digest do
      reopen_store(state)
      {:reply, :ok, %{state | mode: :open}}
    else
      _ -> {:reply, {:error, :fence_mismatch}, state}
    end
  end

  def handle_call({:resume, _fence_id, _secret}, _from, state),
    do: {:reply, {:error, :fence_mismatch}, state}

  def handle_call(:fence, _from, %{mode: {:fenced, fence_id, _}} = state),
    do: {:reply, fence_id, state}

  def handle_call(:fence, _from, state), do: {:reply, nil, state}

  @impl true
  def handle_info({:drain_bound, token}, %{mode: {:draining, from, _h, _t, token}} = state) do
    GenServer.reply(from, {:error, {:quiesce_timeout, state.bound_ms}})
    {:noreply, %{state | mode: :open}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # The drain completes when no ticket is outstanding: close the store, read the observation
  # with admission still closed, then hold the fence or reopen on an incomplete observation.
  defp maybe_complete(%{mode: {:draining, from, digest, timer, _token}, tickets: tickets} = state)
       when map_size(tickets) == 0 do
    state.timer.cancel(timer)
    close_store(state)

    case observe(state) do
      {:ok, observation} ->
        fence_id = "fence_" <> hex(:crypto.strong_rand_bytes(16))
        GenServer.reply(from, {:ok, %{fence_id: fence_id, observation: observation}})
        %{state | mode: {:fenced, fence_id, digest}}

      {:error, dimension} ->
        reopen_store(state)
        GenServer.reply(from, {:error, {:observation_incomplete, dimension}})
        %{state | mode: :open}
    end
  end

  defp maybe_complete(state), do: state

  defp observe(state) do
    state.observe.()
  catch
    _, _ -> {:error, "receipts"}
  end

  defp close_store(%{store: nil}), do: :ok
  defp close_store(%{store: store}), do: AiPair.Delivery.ReceiptStore.close_admission(store)

  defp reopen_store(%{store: nil}), do: :ok
  defp reopen_store(%{store: store}), do: AiPair.Delivery.ReceiptStore.reopen_admission(store)

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
end
