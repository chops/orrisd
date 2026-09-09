defmodule AiPair.Inbox do
  @moduledoc """
  Resolves the runtime inbox directory.

  Order of precedence:
    1. `AI_PAIR_INBOX` environment variable, if set and non-empty
    2. Default `$HOME/.ai-agent-inbox/ai-pair`

  launchd LaunchAgents and systemd user units do not inherit `.envrc`,
  so the default must work on its own. `resolve!/0` raises rather than
  returning a partial result if the path is missing, unwritable, or
  sitting under a mix project.
  """

  require OpenTelemetry.Tracer, as: Tracer

  @subdirs ~w(sock fingerprints logs state inbox outbox processed)

  @spec default_path() :: String.t()
  def default_path do
    Path.join(System.user_home!(), ".ai-agent-inbox/ai-pair")
  end

  @spec resolve!() :: String.t()
  def resolve! do
    Tracer.with_span "inbox.resolve" do
      {source, raw_path} = inbox_source()
      Tracer.set_attribute("inbox.source", Atom.to_string(source))

      path = Path.expand(raw_path)
      Tracer.set_attribute("inbox.path", path)

      with :ok <- check_source_tree(path),
           :ok <- ensure_directory(path),
           :ok <- check_canonical(path),
           :ok <- ensure_writable(path),
           :ok <- ensure_subdirs(path),
           :ok <- chmod_sock(path) do
        path
      else
        {:error, reason, message} ->
          Tracer.set_attribute("inbox.error_reason", Atom.to_string(reason))
          Tracer.set_status(:error, message)
          raise message
      end
    end
  end

  defp inbox_source do
    case System.get_env("AI_PAIR_INBOX") do
      nil -> {:default, default_path()}
      "" -> {:default, default_path()}
      value -> {:env, value}
    end
  end

  defp check_source_tree(path) do
    cond do
      mix_exs_above?(path) ->
        {:error, :mix_project, "AI_PAIR_INBOX must not live under a mix project: #{path}"}

      Enum.any?(forbidden_prefixes(), &String.starts_with?(path, &1)) ->
        {:error, :source_tree, "AI_PAIR_INBOX must not live under a source tree: #{path}"}

      true ->
        :ok
    end
  end

  defp check_canonical(path) do
    canonical = canonical_path(path)
    if canonical != path, do: check_source_tree(canonical), else: :ok
  end

  defp ensure_directory(path) do
    case File.mkdir_p(path) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, :mkdir_failed,
         "AI_PAIR_INBOX mkdir failed at #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp ensure_writable(path) do
    probe = Path.join(path, ".write_probe")

    case File.write(probe, "") do
      :ok ->
        _ = File.rm(probe)
        :ok

      {:error, reason} ->
        {:error, :not_writable,
         "AI_PAIR_INBOX is not writable at #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp ensure_subdirs(path) do
    Enum.reduce_while(@subdirs, :ok, fn name, _acc ->
      sub = Path.join(path, name)

      case File.mkdir_p(sub) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt,
           {:error, :subdir_mkdir_failed,
            "AI_PAIR_INBOX subdir #{sub} mkdir failed: #{:file.format_error(reason)}"}}
      end
    end)
  end

  defp chmod_sock(path) do
    case File.chmod(Path.join(path, "sock"), 0o700) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, :chmod_failed,
         "AI_PAIR_INBOX sock chmod failed at #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp canonical_path(path) do
    case canonical_walk(Path.split(path), [], 16) do
      {:ok, canon} -> canon
      {:error, _} -> path
    end
  end

  defp canonical_walk(_remaining, _acc, 0), do: {:error, :too_many_links}

  defp canonical_walk([], acc, _fuel) do
    {:ok, Path.join(Enum.reverse(acc))}
  end

  defp canonical_walk([part | rest], acc, fuel) do
    candidate = Path.join(Enum.reverse([part | acc]))

    case :file.read_link(candidate) do
      {:ok, target_charlist} ->
        target = List.to_string(target_charlist)

        next_parts =
          if Path.type(target) == :absolute do
            Path.split(target)
          else
            parent_path = Path.join(Enum.reverse(acc))
            target |> Path.expand(parent_path) |> Path.split()
          end

        canonical_walk(next_parts ++ rest, [], fuel - 1)

      {:error, _} ->
        canonical_walk(rest, [part | acc], fuel)
    end
  end

  defp forbidden_prefixes do
    home = System.user_home!()
    [Path.join(home, "src") <> "/", Path.join(home, "code") <> "/"]
  end

  defp mix_exs_above?(path) do
    path
    |> Stream.unfold(fn
      "/" -> nil
      p -> {p, Path.dirname(p)}
    end)
    |> Enum.any?(fn dir -> File.regular?(Path.join(dir, "mix.exs")) end)
  end
end
