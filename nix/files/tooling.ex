defmodule AiPair.Tooling do
  @moduledoc false

  def main(["get", default | path]) do
    value = IO.read(:stdio, :eof) |> JSON.decode!() |> get_path(path)
    IO.puts(if value in [nil, false], do: default, else: text(value))
  end

  def main(["route", host]) do
    value = IO.read(:stdio, :eof) |> JSON.decode!() |> get_path(["routes", host])
    if value in [nil, false], do: System.halt(1), else: IO.puts(JSON.encode!(value))
  end

  def main(["token-expiry", path]) do
    value =
      case File.read(path) do
        {:ok, bytes} -> token_expiry(bytes, System.system_time(:second))
        _ -> "unknown"
      end

    IO.puts(value)
  end

  def get_path(value, []), do: value
  def get_path(value, [key | rest]) when is_map(value), do: get_path(Map.get(value, key), rest)
  def get_path(_, _), do: nil

  def token_expiry(bytes, now) do
    with {:ok, auth} <- JSON.decode(bytes),
         token when is_binary(token) <- get_path(auth, ["tokens", "access_token"]),
         [_header, payload | _] <- String.split(token, "."),
         {:ok, decoded} <- Base.url_decode64(String.trim_trailing(payload, "="), padding: false),
         {:ok, claims} when is_map(claims) <- JSON.decode(decoded),
         expiry when is_number(expiry) <- numeric(Map.get(claims, "exp", 0)) do
      remaining = expiry - now

      cond do
        remaining <= 0 -> "expired"
        remaining < 3600 -> "soon"
        true -> "ok"
      end
    else
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
  end

  defp numeric(true), do: 1
  defp numeric(false), do: 0
  defp numeric(value), do: value
  defp text(value) when is_binary(value), do: value
  defp text(value), do: JSON.encode!(value)
end
