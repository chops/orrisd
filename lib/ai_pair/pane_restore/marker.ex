defmodule AiPair.PaneRestore.Marker do
  @moduledoc """
  Reads and writes the session-local ownership marker
  (contract: `docs/contracts/tmux-session-marker.org`).

  The marker records which owner root first claimed a tmux session, and for
  which boot incarnation. It is stored in the session user option
  `@ai_pair_session_incarnation` as a JSON object, so it lives and dies with the
  tmux session rather than with any process of ours: a daemon that restarts
  finds the marker its predecessor left, and a session that ends takes the
  marker with it. A session is addressed by its stable id (`$N`), never by its
  reusable name.

  ## What this module refuses to do

  It never repairs and never steals. A marker that does not decode to the exact
  documented shape is reported as malformed and left byte-for-byte alone; a
  marker owned by another root is reported as foreign and left alone. Repairing
  either would destroy the evidence that something else is managing the session.

  `ensure/3` writes only after observing absence, and then only conditionally
  (`set-option -o`), and then reads the option back: the read-back is the only
  evidence of what tmux stored. An existing same-owner marker is used unchanged,
  including its generation. A restarted daemon never replaces that claim with
  its new boot generation, and no call path here issues an unconditional
  `set-option`.

  ## Failure vocabulary

  Every failure payload is a marker finding of `AiPair.PaneRestore.Admission`,
  so a caller passes it through to that module's marker source verbatim rather
  than translating it:

      {:marker_absent}                  the session carries no marker
      {:marker_malformed, raw}          a value is present but is not a marker
      {:marker_foreign, owner_root}     a marker is present and owned elsewhere
      {:source_unavailable, :marker}    the adapter could not be asked
      {:source_error, :marker, term}    the adapter was asked and tmux failed

  Observed absence and unavailability are deliberately distinct: the first says
  there is no marker, the second says we do not know whether there is one. The
  wire vocabulary's `marker_unavailable` covers the two bottom rows; the reader
  keeps them apart.

  ## How tmux is invoked

  Both option commands go through `AiPair.Tmux.show_options/3` and
  `AiPair.Tmux.set_option_if_absent/4`, which run them from the adapter's own
  process, so they take their place in that adapter's mailbox alongside every
  other tmux invocation in the system. This module holds no binary, socket or
  other invocation context of its own, and reads none out of the adapter.
  """

  alias AiPair.Tmux

  @option "@ai_pair_session_incarnation"
  @version 1

  # record.ex validates `session_gen` against exactly this shape, and Admission
  # compares the two as text. A generation this module would accept but a
  # record never could is a marker that can never match anything.
  @generation_format ~r/\A[0-9]+\z/

  # tmux 3.7c says "invalid option" for an unset user option; older releases
  # said "unknown option". Both name the same condition.
  @absent_markers ["invalid option", "unknown option"]

  @typedoc "A nonempty UTF-8 binary, compared exactly and without normalization."
  @type text :: binary()

  @typedoc "The tmux session id (`$0`), never the reusable session name."
  @type session_id :: text()

  @type marker :: %{
          version: 1,
          owner_root: text(),
          session_id: session_id(),
          generation: text()
        }

  @type failure ::
          {:marker_absent}
          | {:marker_malformed, binary()}
          | {:marker_foreign, text()}
          | {:source_unavailable, :marker}
          | {:source_error, :marker, term()}

  @doc """
  Ensures the session carries a marker for `owner_root`, offering `generation`
  only when the marker is absent.

  The steps are those of the contract's write discipline: read; a present
  same-owner marker is `:ok` without any write, whatever its generation; a
  foreign one is `{:error, {:marker_foreign, other_root}}`; a malformed one or
  a failed read is returned as the reader's finding; only an absent marker
  leads to one `set-option -o` with the encoded desired marker, followed by a
  read-back that decides the result.

  The read-back rules: a same-owner winner is `:ok` (the loser of a race adopts
  the winner's generation, so call `read/2` for the generation actually
  recorded); a foreign winner is `{:marker_foreign, _}`; a malformed value is
  `{:marker_malformed, _}`. An absent read-back is `{:marker_absent}` after a
  write that reported success, `{:source_error, :marker, error}` after a failed
  write, where `error` is what the adapter returned, including the typed
  `:option_exists` of a lost race whose winner was removed again before the
  read-back, and `{:source_unavailable, :marker}` when the adapter did not
  answer the write. `{:error, :option_exists}` from the conditional write is
  the ordinary lost-race signal, never a failure by itself: the read-back names
  the winner.

  `owner_root` must be an absolute path and `generation` a decimal string; both
  are produced by this system rather than observed from the session, so a bad
  value is a caller defect and raises rather than returning a finding.
  """
  @spec ensure(GenServer.server(), session_id(), keyword()) :: :ok | {:error, failure()}
  def ensure(server, session_id, opts) when is_binary(session_id) and is_list(opts) do
    desired = desired_marker!(session_id, opts)
    ensure_written(server, session_id, desired)
  end

  @doc """
  Mints a boot generation: 16 cryptographically random bytes decoded as an
  unsigned integer and rendered in decimal (1 to 39 digits). It is entropy,
  never a clock or a process id.
  """
  @spec mint_generation() :: String.t()
  def mint_generation do
    :crypto.strong_rand_bytes(16)
    |> :binary.decode_unsigned()
    |> Integer.to_string()
  end

  @doc """
  Reads the marker stored on `session_id`.

  The stored `session_id` is reported verbatim rather than checked against the
  session it was read from: a marker naming another session is a mismatch for
  `AiPair.PaneRestore.Admission` to report against a live observation, not a
  malformed marker.
  """
  @spec read(GenServer.server(), session_id()) :: {:ok, marker()} | {:error, failure()}
  def read(server, session_id) when is_binary(session_id) do
    read_marker(server, session_id)
  end

  # --- writing ------------------------------------------------------------

  defp ensure_written(server, session_id, desired) do
    case read_marker(server, session_id) do
      {:ok, marker} -> ensure_against(desired, marker)
      {:error, {:marker_absent}} -> write(server, session_id, desired)
      {:error, _finding} = error -> error
    end
  end

  defp ensure_against(%{owner_root: root}, %{owner_root: root}), do: :ok

  defp ensure_against(_desired, %{owner_root: other}) do
    {:error, {:marker_foreign, other}}
  end

  # The conditional write's own answer is never taken as evidence of what tmux
  # stored: success, a refused `-o` write (another claimant won) and any other
  # failure all lead to the same read-back, which alone decides. The write's
  # answer matters only when the read-back finds nothing.
  defp write(server, session_id, marker) do
    result = set_option_if_absent(server, session_id, encode(marker))

    case read_marker(server, session_id) do
      {:ok, winner} -> ensure_against(marker, winner)
      {:error, {:marker_absent}} -> absent_after_write(result)
      {:error, _finding} = error -> error
    end
  end

  defp absent_after_write(:ok), do: {:error, {:marker_absent}}

  defp absent_after_write({:error, error}),
    do: {:error, {:source_error, :marker, error}}

  defp absent_after_write(:unavailable), do: {:error, {:source_unavailable, :marker}}

  # Exactly the four contract members; the encoder emits no whitespace. Member
  # order is not promised to readers.
  defp encode(marker) do
    Jason.encode!(%{
      "version" => marker.version,
      "owner_root" => marker.owner_root,
      "session_id" => marker.session_id,
      "generation" => marker.generation
    })
  end

  # --- reading ------------------------------------------------------------

  defp read_marker(server, session_id) do
    case show_option(server, session_id) do
      {:ok, output} -> decode(output)
      {:error, error} -> {:error, show_failure(error)}
      :unavailable -> {:error, {:source_unavailable, :marker}}
    end
  end

  # An unset user option and an unusable target both exit 1, and collapsing them
  # would report a session we cannot address as a session with no marker. tmux
  # distinguishes them only in its message; `-q` would erase the distinction
  # rather than resolve it.
  defp show_failure(%{stderr: stderr} = error) do
    if Enum.any?(@absent_markers, &String.contains?(stderr, &1)) do
      {:marker_absent}
    else
      {:source_error, :marker, error}
    end
  end

  # `show-options -v` prints the value followed by one newline; the stored value
  # carries none. The trimmed value is the `raw` of every malformed finding.
  defp decode(output) do
    raw = String.trim_trailing(output, "\n")

    with {:ok, ordered} <- Jason.decode(raw, objects: :ordered_objects),
         {:ok, plain} <- reject_duplicate_keys(ordered) do
      validated(plain, raw)
    else
      _ -> {:error, {:marker_malformed, raw}}
    end
  end

  # A duplicate object key is a decode-level defect: the bytes do not denote one
  # unambiguous document. Jason's default decoder silently keeps the last
  # occurrence, so ordered objects are decoded and duplicates are rejected, at
  # every depth, before any shape check sees the document.
  defp reject_duplicate_keys(%Jason.OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if length(Enum.uniq(keys)) == length(keys) do
      Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case reject_duplicate_keys(value) do
          {:ok, plain} -> {:cont, {:ok, Map.put(acc, key, plain)}}
          :error -> {:halt, :error}
        end
      end)
    else
      :error
    end
  end

  defp reject_duplicate_keys(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case reject_duplicate_keys(value) do
        {:ok, plain} -> {:cont, {:ok, [plain | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp reject_duplicate_keys(scalar), do: {:ok, scalar}

  # The key set is exact. A marker carrying an unexpected key was written by
  # something other than this module against the same option, and adopting the
  # part we recognise would be inventing agreement.
  defp validated(
         %{
           "version" => @version,
           "owner_root" => owner_root,
           "session_id" => session_id,
           "generation" => generation
         } = decoded,
         raw
       )
       when map_size(decoded) == 4 do
    if absolute_path?(owner_root) and valid_text?(session_id) and generation?(generation) do
      {:ok,
       %{
         version: @version,
         owner_root: owner_root,
         session_id: session_id,
         generation: generation
       }}
    else
      {:error, {:marker_malformed, raw}}
    end
  end

  defp validated(_decoded, raw), do: {:error, {:marker_malformed, raw}}

  # --- adapter calls ------------------------------------------------------

  # Every tmux command this module issues is one `GenServer.call` into the
  # adapter, so it runs in the adapter's process and is ordered by its mailbox
  # against all other tmux work. Which tmux server is addressed (binary and
  # socket) is the adapter's own state and is never read out of it here.
  #
  # A call that does not come back is `:unavailable`: a stopped or unregistered
  # adapter, or one that did not answer inside its own deadline. That is the
  # "we could not look" arm of this module's vocabulary and it is deliberately
  # not an observation. An adapter that never ran `show-options` has learned
  # nothing about the marker, so reporting it as an absent marker would be
  # inventing an observation rather than recording one.
  #
  # The bare atom is unambiguous because the adapter answers only
  # `{:ok, binary}`, `:ok` or `{:error, _}`, never a bare atom.
  defp show_option(server, session_id) do
    Tmux.show_options(session_id, @option, server)
  catch
    :exit, _reason -> :unavailable
  end

  defp set_option_if_absent(server, session_id, value) do
    Tmux.set_option_if_absent(session_id, @option, value, server)
  catch
    :exit, _reason -> :unavailable
  end

  # --- caller-supplied values ---------------------------------------------

  defp desired_marker!(session_id, opts) do
    %{
      version: @version,
      owner_root: validated_root!(Keyword.fetch!(opts, :owner_root)),
      session_id: session_id,
      generation: validated_generation!(Keyword.fetch!(opts, :generation))
    }
  end

  defp validated_root!(owner_root) do
    if absolute_path?(owner_root) do
      owner_root
    else
      raise ArgumentError, "owner_root must be an absolute path, got: #{inspect(owner_root)}"
    end
  end

  defp validated_generation!(generation) do
    if generation?(generation) do
      generation
    else
      raise ArgumentError, "generation must be a decimal string, got: #{inspect(generation)}"
    end
  end

  # --- value predicates ---------------------------------------------------

  defp valid_text?(value), do: is_binary(value) and byte_size(value) > 0 and String.valid?(value)

  defp absolute_path?(value), do: valid_text?(value) and Path.type(value) == :absolute

  defp generation?(value), do: valid_text?(value) and Regex.match?(@generation_format, value)
end
