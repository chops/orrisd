defmodule AiPair.Delivery.Payload do
  @moduledoc """
  In-memory delivery bytes with payload-free ordinary inspection.

  No JSON or string protocol is implemented. This is an accidental-disclosure
  guard, not memory isolation: deliberate field access or structs: false bypasses
  it. Versioned pane calls and queued entries retain this wrapper until paste.
  """

  @enforce_keys [:bytes, :hash, :size]
  defstruct [:bytes, :hash, :size]

  def new(bytes) when is_binary(bytes) do
    %__MODULE__{
      bytes: bytes,
      size: byte_size(bytes),
      hash: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    }
  end

  def hash(%__MODULE__{hash: hash}), do: hash
  def reveal(%__MODULE__{bytes: bytes}), do: bytes

  defimpl Inspect do
    def inspect(%{hash: hash, size: size}, _opts),
      do: "#DeliveryPayload<#{hash} #{size} bytes>"
  end
end
