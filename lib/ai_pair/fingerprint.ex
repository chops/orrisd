defmodule AiPair.Fingerprint do
  @moduledoc """
  Loads JSON fingerprint files and matches captured pane text against them.

  ## Format

      {
        "tui": "claude_code",
        "version": 1,
        "normalize": {"width": 80, "height": 24, "strip_ansi": true},
        "states": {
          "idle": {
            "bottom_lines": 8,
            "all": ["pattern1", "pattern2"],
            "any": []
          },
          "busy": { ... }
        }
      }

  Semantics:
    * `:all` — every regex must match at least one of the bottom-N lines
    * `:any` — at least one regex must match (empty `any` = check skipped)
    * `:bottom_lines` — slice taken from the end of the captured text
    * `:unless_tail` — dialog state only: an ordered list of N regexes. The
      dialog state does not fire when the last N non-blank lines of the
      ANSI-stripped screen match the list one-to-one, in order. Only a
      non-empty proper list of strings that all compile grants the exemption;
      an absent, empty, non-list or partly invalid value, or a screen with
      fewer than N non-blank lines, grants none. Busy and idle ignore the key.

  ## Returns

      match(text, fingerprint) :: {:ok, :idle | :busy | :dialog} | {:error, :no_match}

  Dialog fingerprints are matched before busy and idle so approval overlays
  that leave an idle composer prompt visible underneath still block sends.
  `unless_tail` exempts only a screen that ends with the exact composer tail;
  the measured Codex approval overlay does not end that way.
  """

  @type fingerprint :: map()
  @type matched_state :: :idle | :busy | :dialog

  @spec load(Path.t()) :: {:ok, fingerprint()} | {:error, term()}
  def load(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded}
    end
  end

  @spec load!(Path.t()) :: fingerprint()
  def load!(path) do
    case load(path) do
      {:ok, fp} -> fp
      {:error, reason} -> raise "fingerprint load failed at #{path}: #{inspect(reason)}"
    end
  end

  @spec match(binary(), fingerprint()) :: {:ok, matched_state()} | {:error, :no_match}
  def match(captured, fingerprint) when is_binary(captured) and is_map(fingerprint) do
    stripped = if normalize_strip_ansi?(fingerprint), do: strip_ansi(captured), else: captured
    states = Map.get(fingerprint, "states", %{})

    cond do
      dialog_matches?(stripped, Map.get(states, "dialog")) -> {:ok, :dialog}
      state_matches?(stripped, Map.get(states, "busy")) -> {:ok, :busy}
      state_matches?(stripped, Map.get(states, "idle")) -> {:ok, :idle}
      true -> {:error, :no_match}
    end
  end

  defp dialog_matches?(stripped, spec) do
    state_matches?(stripped, spec) and not tail_exempt?(stripped, spec)
  end

  defp tail_exempt?(stripped, %{"unless_tail" => patterns}) do
    case compile_tail(patterns) do
      {:ok, regexes} ->
        n = length(regexes)

        tail =
          stripped
          |> String.split("\n")
          |> Enum.reject(&(String.trim(&1) == ""))
          |> Enum.take(-n)

        length(tail) == n and
          tail |> Enum.zip(regexes) |> Enum.all?(fn {line, re} -> Regex.match?(re, line) end)

      :error ->
        false
    end
  end

  defp tail_exempt?(_stripped, _spec), do: false

  # All or nothing: one non-string member, invalid regex or improper tail
  # voids the whole list rather than dropping that member.
  defp compile_tail([_ | _] = patterns), do: compile_tail(patterns, [])
  defp compile_tail(_patterns), do: :error

  defp compile_tail([], acc), do: {:ok, Enum.reverse(acc)}

  defp compile_tail([pattern | rest], acc) when is_binary(pattern) do
    case Regex.compile(pattern, "u") do
      {:ok, re} -> compile_tail(rest, [re | acc])
      {:error, _} -> :error
    end
  end

  defp compile_tail(_patterns, _acc), do: :error

  defp state_matches?(_stripped, nil), do: false

  defp state_matches?(stripped, %{} = spec) do
    bottom = bottom_lines(stripped, Map.get(spec, "bottom_lines", 12))
    all_patterns = Map.get(spec, "all", [])
    any_patterns = Map.get(spec, "any", [])

    all_ok? = Enum.all?(all_patterns, fn p -> any_line_matches?(bottom, p) end)

    any_ok? =
      case any_patterns do
        [] -> true
        ps -> Enum.any?(ps, fn p -> any_line_matches?(bottom, p) end)
      end

    all_ok? and any_ok?
  end

  defp any_line_matches?(lines, pattern) do
    case Regex.compile(pattern, "u") do
      {:ok, re} -> Enum.any?(lines, &Regex.match?(re, &1))
      {:error, _} -> false
    end
  end

  defp bottom_lines(text, n) do
    text
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.drop_while(&(String.trim(&1) == ""))
    |> Enum.take(n)
    |> Enum.reverse()
  end

  defp normalize_strip_ansi?(fingerprint) do
    case fingerprint do
      %{"normalize" => %{"strip_ansi" => false}} -> false
      _ -> true
    end
  end

  defp strip_ansi(binary) do
    Regex.replace(~r/\e\[[0-9;?]*[ -\/]*[@-~]/, binary, "")
  end
end
