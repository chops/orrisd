defmodule AiPair.Admission.Timer do
  @moduledoc """
  The production drain timer of AiPair.Admission: Process.send_after/3. Tests inject a timer
  with the same two functions that never fires by itself (RB-3a producer scope r3, A3).
  """

  @spec arm(pid(), non_neg_integer(), term()) :: reference()
  def arm(dest, ms, message), do: Process.send_after(dest, message, ms)

  @spec cancel(reference()) :: :ok
  def cancel(ref) do
    _ = Process.cancel_timer(ref)
    :ok
  end
end
