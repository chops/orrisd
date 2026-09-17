defmodule AiPair.TelemetryBatch do
  @moduledoc false

  def main([curl, tempo, query, first, last, limit, output]) do
    limit = String.to_integer(limit)
    window = ["--data-urlencode", "start=#{first}", "--data-urlencode", "end=#{last}"]
    fetch = fn path, params -> fetch(curl, tempo <> path, params ++ window) end

    tags =
      fetch.("/api/v2/search/tag/span.gen_ai.system/values", ["--data-urlencode", "q={ #{query} }"])

    providers = providers(tags)
    cap = limit |> Kernel.*(2) |> max(20) |> min(200)

    searches = [
      "{ #{query} }"
      | Enum.map(providers, &"{ #{query} && span.gen_ai.system = #{JSON.encode!(&1)} }")
    ]

    candidates =
      Enum.flat_map(searches, fn search ->
        fetch.("/api/search", [
          "--data-urlencode",
          "q=#{search}",
          "--data-urlencode",
          "limit=#{cap}"
        ])
        |> candidates()
      end)
      |> newest()
      |> Enum.uniq_by(&elem(&1, 1))

    extractable =
      Enum.flat_map(candidates, fn {time, id} ->
        if Regex.match?(~r/\A[A-Za-z0-9._-]+\z/, id) do
          case extract(fetch(curl, tempo <> "/api/traces/" <> id, []), id) do
            {:ok, provider, summary} -> [{time, id, provider, summary}]
            :skip -> []
          end
        else
          []
        end
      end)

    selected = select(extractable, limit)

    batch =
      selected
      |> Enum.with_index(1)
      |> Enum.map(fn {row, index} ->
        ["===== call #{index} =====\n", elem(row, 3), "\n\n\n"]
      end)

    File.write!(output, batch)
    IO.puts(length(selected))
    IO.puts(length(candidates))
    IO.puts(provider_summary(selected))
  end

  def providers(tags) do
    discovered =
      Enum.flat_map(collection(tags, "tagValues"), fn
        %{"value" => value} when is_binary(value) -> [value]
        value when is_binary(value) -> [value]
        _ -> []
      end)

    (["anthropic", "openai-codex"] ++ discovered)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  def candidates(response) do
    response
    |> collection("traces")
    |> Enum.flat_map(fn
      %{"startTimeUnixNano" => time, "traceID" => id} when is_binary(id) ->
        [{display(time), id}]

      _ ->
        []
    end)
  end

  defp collection(response, key) do
    case Map.get(response, key) do
      rows when is_list(rows) -> rows
      _ -> []
    end
  end

  def select(rows, limit) do
    ordered = newest(rows)
    reserved = ordered |> Enum.uniq_by(&elem(&1, 2)) |> Enum.take(limit)
    ids = MapSet.new(reserved, &elem(&1, 1))

    (reserved ++ Enum.reject(ordered, &MapSet.member?(ids, elem(&1, 1))))
    |> Enum.take(limit)
    |> Enum.sort_by(&{elem(&1, 0), elem(&1, 1)})
  end

  def provider_summary(rows) do
    counts = Enum.frequencies_by(rows, &elem(&1, 2))

    names =
      ["anthropic", "openai-codex"] ++
        ((Map.keys(counts) -- ["anthropic", "openai-codex"]) |> Enum.sort())

    Enum.map_join(names, ", ", &"#{&1}=#{Map.get(counts, &1, 0)}")
  end

  def extract(trace, id) do
    attributes =
      for batch <- Map.get(trace, "batches", []),
          scope <- Map.get(batch, "scopeSpans", []),
          span <- Map.get(scope, "spans", []),
          attribute <- Map.get(span, "attributes", []),
          do: attribute

    first = fn key ->
      Enum.find_value(attributes, fn
        %{"key" => ^key, "value" => %{"stringValue" => value}}
        when is_binary(value) and value != "" ->
          value

        _ ->
          nil
      end)
    end

    provider = first.("gen_ai.system")

    if provider && first.("http.request.method") == "POST" do
      values =
        Enum.reduce(attributes, %{}, fn
          %{"key" => key, "value" => value}, acc when is_map(value) ->
            Map.put(
              acc,
              key,
              Enum.find_value(
                ["stringValue", "intValue", "boolValue", "doubleValue"],
                "",
                &Map.get(value, &1)
              )
            )

          _, acc ->
            acc
        end)

      get = fn key, default -> display(Map.get(values, key) || default) end

      summary = """
      trace_id: #{id}
      provider: #{get.("gen_ai.system", "?")}
      http_method: #{get.("http.request.method", "?")}
      model: #{get.("gen_ai.request.model", "?")}
      agent: #{display(values["ai_pair.pane.agent"] || values["ai_pair.harness"] || "?")}
      project: #{get.("ai_pair.project", "<none>")}
      correlation_id: #{get.("messaging.message.id", "<none>")}
      operation: #{get.("gen_ai.operation.name", "?")}
      finish_reason: #{get.("gen_ai.response.finish_reasons", "?")}
      tokens: input=#{get.("gen_ai.usage.input_tokens", "?")} output=#{get.("gen_ai.usage.output_tokens", "?")} cache_read=#{get.("gen_ai.usage.cache_read_input_tokens", "?")} cache_creation=#{get.("gen_ai.usage.cache_creation_input_tokens", "?")}
      prompt_size_bytes: #{get.("gen_ai.prompt.size_bytes", "?")} (truncated=#{get.("gen_ai.prompt.truncated", "false")})
      --- PROMPT PREVIEW ---
      #{get.("gen_ai.prompt", "") |> String.codepoints() |> Enum.take(800) |> Enum.join()}
      --- RESPONSE PREVIEW ---
      #{get.("gen_ai.completion", "") |> String.codepoints() |> Enum.take(500) |> Enum.join()}
      """

      {:ok, provider, String.trim_trailing(summary, "\n")}
    else
      :skip
    end
  rescue
    _ -> :skip
  end

  defp newest(rows),
    do:
      Enum.sort(rows, fn a, b ->
        elem(a, 0) > elem(b, 0) or (elem(a, 0) == elem(b, 0) and elem(a, 1) <= elem(b, 1))
      end)

  defp display(value) when is_binary(value), do: value
  defp display(value), do: JSON.encode!(value)

  defp fetch(curl, url, params) do
    case System.cmd(curl, ["-s", "--get", url | params]) do
      {bytes, 0} ->
        case JSON.decode(bytes) do
          {:ok, value} when is_map(value) -> value
          _ -> %{}
        end

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end
end
