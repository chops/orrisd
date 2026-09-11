defmodule AiPair.Test.PaneIntentScriptedIo do
  @moduledoc """
  Scripts the `:file` primitives behind `SystemFs.directory_sync/3` so the sync
  and close substeps become inducible.

  They are not inducible against a real filesystem: opening a directory
  read-only and syncing it succeeds, and there is no precondition that makes
  `:file.sync/1` fail on a descriptor we just opened. Without this the checking
  of those substeps could only be asserted by reading the source, which is a
  claim about code rather than a measurement of behaviour.

  This scripted I/O double is defined beside its contract controls.

  State lives in the process dictionary rather than an Agent on purpose. The
  calls under test are synchronous and happen in the test process, so there is
  nothing to supervise and nothing to stop - and an Agent would reintroduce the
  check-then-act teardown race that already produced one flaky row in this suite.

  Every call is recorded IN ORDER, including its arguments, so a control can
  prove that close was attempted after a failing sync rather than infer it.

  `open: :real` opens the directory for real through `:file`, which is what the
  owned-descriptor controls need: a scripted close failure then leaves a GENUINE
  descriptor open, instead of fabricating an error against a file that was never
  opened.
  """

  @key __MODULE__

  @doc """
  Arm the script. `:sync` and `:close` each take the value the corresponding
  primitive should return; both default to `:ok`. `:open` may be `:scripted`
  (default, no real descriptor) or `:real` (open through `:file`).
  """
  def script(opts \\ []) do
    Process.put(@key, %{
      sync: Keyword.get(opts, :sync, :ok),
      close: Keyword.get(opts, :close, :ok),
      open: Keyword.get(opts, :open, :scripted),
      barrier: Keyword.get(opts, :barrier, nil),
      dir: nil,
      calls: []
    })

    :ok
  end

  @doc "The recorded calls, in the order they were made."
  def calls do
    case Process.get(@key) do
      %{calls: calls} -> Enum.reverse(calls)
      nil -> []
    end
  end

  def open(path, options) do
    record({:open, path, options})
    s = state()
    Process.put(@key, %{s | dir: path})

    case s.open do
      :scripted -> {:ok, {:scripted_fd, path}}
      :real -> :file.open(path, options)
      other -> other
    end
  end

  def sync(fd) do
    record({:sync, fd})
    s = state()

    case {s.open, s.sync} do
      # Really opened and scripted to succeed: really SYNC it. Returning a
      # synthetic :ok while calling the resource "synced" would label a
      # durability step that never happened - the same shape as a fabricated
      # close error against a file that was never opened.
      {:real, :ok} -> :file.sync(fd)
      {_open, result} -> result
    end
  end

  def close(fd) do
    record({:close, fd})
    s = state()

    case {s.open, s.close} do
      # Really opened and scripted to succeed: really close it.
      {:real, :ok} ->
        :file.close(fd)

      # Really opened and scripted to FAIL: deliberately do not close, so the
      # descriptor is genuinely left open. That leaked fd is the whole point of
      # the owned-resource controls - a fabricated close error against a file
      # that was never opened proves nothing about reclamation.
      {_open, result} ->
        hand_off(s, fd)
        result
    end
  end

  # The barrier hands the raw term and the owning pid to a surviving observer and
  # then WAITS, still inside the real backend body. Without that pause the owner
  # would conclude and exit before any census could run, so a positive live-FD
  # observation would be impossible to take at all.
  defp hand_off(%{barrier: nil}, _fd), do: :ok

  defp hand_off(%{barrier: observer, dir: dir}, fd) do
    send(observer, {:leaked_fd, dir, fd, self()})

    receive do
      :continue -> :ok
    after
      5_000 -> :ok
    end
  end

  defp state do
    Process.get(@key) ||
      raise "PaneIntentScriptedIo used without script/1; arm it first so the return values are explicit"
  end

  defp record(call) do
    s = state()
    Process.put(@key, %{s | calls: [call | s.calls]})
    :ok
  end
end

defmodule AiPair.Test.PaneIntentLeakyDirSync do
  @moduledoc """
  A backend that leaks a REAL directory descriptor on the product path.

  H3 requires actual owned-resource evidence, and a fabricated close error is not
  that: injecting a precomputed `{:close, _}` through the fault double returns
  before any backend open, so no descriptor ever exists and nothing about
  reclamation is being observed.

  This backend arms a trusted IO adapter and calls the ACTUAL
  `SystemFs.directory_sync/3`. An earlier revision implemented its own
  open/sync/close pipeline, which meant every claim it supported was about my
  reimplementation rather than about the product: G6 requires the same
  arity-three body, and a parallel test-only directory_sync is exactly what it
  forbids. Routing through the real body also means a COMBINED sync+close reason
  is composed by the product, not hand-built here.

  Config rides in the Fs handle's own state rather than the process dictionary,
  because the owner runs in a different process from the test and would not see a
  process-dictionary script at all. The adapter is then armed inside the owner
  process, where its own process dictionary is the right scope.

  The fd handoff and pause live in the adapter's close, so the barrier happens
  while control is still inside the real backend body.
  """
  alias AiPair.PaneIntentStore.Fs.SystemFs

  for {op, arity} <- [
        lstat: 1,
        mkdir: 1,
        chmod: 2,
        open_exclusive: 1,
        read: 1,
        write: 2,
        file_sync: 1,
        close: 1,
        rename: 2,
        unlink: 1
      ] do
    args = Macro.generate_arguments(arity, __MODULE__)

    def unquote(op)(_state, unquote_splicing(args)),
      do: apply(SystemFs, unquote(op), [nil, unquote_splicing(args)])
  end

  def directory_sync(%{target: target, observer: observer} = state, dir) do
    if String.ends_with?(dir, target) do
      io_opts =
        state
        |> Map.get(:io, close: {:error, :ebadf})
        |> Keyword.put(:open, :real)
        |> Keyword.put(:barrier, observer)

      AiPair.Test.PaneIntentScriptedIo.script(io_opts)

      SystemFs.directory_sync(nil, dir, AiPair.Test.PaneIntentScriptedIo)
    else
      SystemFs.directory_sync(nil, dir)
    end
  end
end

defmodule AiPair.Test.PaneIntentLeakyTempClose do
  @moduledoc """
  Leaves a REAL temporary-file descriptor open by failing its cleanup close.

  The temp-close controls elsewhere in this file observe cleanup entries and the
  owner's DOWN, but never the descriptor itself. H3 requires temp AND directory
  resources to carry positive-FD, retained-term and reclamation evidence, so this
  fixture supplies a genuine open file descriptor rather than a reported error.

  The path is captured at `open_exclusive` because the seam's `close/2` receives
  only the handle, and the census needs a target to match exactly.

  The barrier fires inside `close`, which is deliberately BEFORE the unlink that
  follows it: once the temp file is unlinked, lsof reports the name with a
  "(deleted)" suffix and exact NAME matching would count zero - the census would
  report absence while the descriptor was still open. Observing at the barrier
  keeps the measurement honest.

  No production behaviour is being changed or newly claimed here: the cleanup
  close failure already lands in cleanup_errors and already bounds the owner.
  This only adds the resource observation that was missing.
  """
  alias AiPair.PaneIntentStore.Fs.SystemFs

  @key __MODULE__

  for {op, arity} <- [
        lstat: 1,
        mkdir: 1,
        chmod: 2,
        read: 1,
        file_sync: 1,
        rename: 2,
        unlink: 1,
        directory_sync: 1
      ] do
    args = Macro.generate_arguments(arity, __MODULE__)

    def unquote(op)(_state, unquote_splicing(args)),
      do: apply(SystemFs, unquote(op), [nil, unquote_splicing(args)])
  end

  def open_exclusive(_state, path) do
    Process.put(@key, path)
    SystemFs.open_exclusive(nil, path)
  end

  def write(%{fail_write: true}, _fd, _bytes), do: {:error, :enospc}
  def write(_state, fd, bytes), do: SystemFs.write(nil, fd, bytes)

  def close(%{observer: observer}, fd) do
    send(observer, {:leaked_temp_fd, Process.get(@key), fd, self()})

    receive do
      :continue -> :ok
    after
      5_000 -> :ok
    end

    {:error, :ebadf}
  end
end

defmodule AiPair.Test.PaneIntentChmodEffectThenError do
  @moduledoc """
  A backend whose chmod has its real EFFECT and then reports failure, once.

  H1 is about an operation that succeeded on the filesystem and still returned an
  error. The fault double cannot express that shape: `{:error, _}` skips the
  effect entirely, and `{:hook, _}` runs before the backend, which then succeeds
  normally. Injecting a plain error instead leaves the directory at its mkdir
  mode, and the store then correctly REFUSES the retry with `:unsafe_mode` -
  correct behaviour, but a different scenario, and not the one H1 describes.

  The "already fired" flag lives in the process dictionary of whichever process
  calls the seam, which is the store's owner. That scopes it per owner, which is
  what a same-owner retry control needs.

  Every directory_sync is reported to `observer`, so the control can ask whether
  the ROOT was synced rather than infer it from a flag.
  """
  alias AiPair.PaneIntentStore.Fs.SystemFs

  for {op, arity} <- [
        lstat: 1,
        mkdir: 1,
        open_exclusive: 1,
        read: 1,
        write: 2,
        file_sync: 1,
        close: 1,
        rename: 2,
        unlink: 1
      ] do
    args = Macro.generate_arguments(arity, __MODULE__)

    def unquote(op)(_state, unquote_splicing(args)),
      do: apply(SystemFs, unquote(op), [nil, unquote_splicing(args)])
  end

  def chmod(%{target: target, observer: observer}, path, mode) do
    result = SystemFs.chmod(nil, path, mode)

    if path == target and not Process.get({__MODULE__, :fired}, false) do
      Process.put({__MODULE__, :fired}, true)
      send(observer, {:chmod_effect_then_error, path, result})
      {:error, :eio}
    else
      result
    end
  end

  def directory_sync(%{observer: observer}, dir) do
    result = SystemFs.directory_sync(nil, dir)
    send(observer, {:directory_sync, dir, result})
    result
  end
end

defmodule AiPair.PaneIntentStoreTest do
  @moduledoc """
  S1-F1 pane intent store contract rows for ADR 0005.

  The owned-file interval begins at temporary creation and runs to the latest
  observed event of the call: the qualifying directory sync is a durability
  milestone, not the API return.

  ## What changed and why

  Two double controls made backend ABSENCE a permanent passing condition. They
  wrapped `assert_raise UndefinedFunctionError` around `lstat` and `mkdir`, and one
  reached `/no-backend`, outside any owned fixture. Once GREEN supplies a real
  backend those calls return ordinary filesystem outcomes and the controls break.
  They now drive `AiPair.Test.PaneIntentScriptedBackend`, which forces a return or a
  raise deterministically whether or not SystemFs exists, and records its own calls
  so a refusal can be proven by NON-ENTRY rather than inferred from a label.

  The oracle accepted a successful subsequence as a valid transaction. It took
  any invoked value except `{:error, _}` as success, so `nil` counted as a completed
  fsync; it matched one write then one sync, so a second write after the sync was
  accepted while the final content was unsynced; and it read `effects/1`, which is
  ordered by ATTEMPT, so a sync attempted before a write returned was accepted. It
  is replaced by an explicit transaction verifier over `timeline/1` records using
  exact per-callback success shapes and requiring a prerequisite's RESULT to precede
  its dependent's ATTEMPT.

  Expected identity was partly inferred from the implementation under test. The
  helper adopted the first opened path as the expected temp, so moving that temp
  outside the state directory made the checker approve the violation by adopting it.
  Identity is now pinned from the fixture before the call; an observed temp is
  adopted only after its parent, distinctness and owned-temp policy are checked.

  The blocked-helper cleanup case establishes only the behavior named by that test.
  Exceptional cleanup under real observer failure requires separate fault-injection
  evidence. This suite's passing tally is not that proof and is not offered as it.

  ## Ownership, durability and validation

  These rows exercise `AiPair.PaneIntentStore` and its filesystem backend:

    * Ownership is claimed by registration BEFORE any filesystem work, so a
      refused competitor produces zero seam effects and a discovered owner never
      serves a healthy empty view while startup is still in flight.
    * The outstanding root-sync obligation survives owner restart, rederived
      from state-directory presence rather than trusted to an in-memory flag.
    * An unresolved close no longer merely reports. The owner terminates in
      the same transition that replies, which is what makes descriptor retention
      finite; the reply, its primary data outcome and both cleanup errors all
      survive. A directory-sync descriptor feeds the same bound.
    * Accepted records are checked not to intern novel values, not just
      rejected ones.
    * The delete fault matrix covers the callbacks a delete MEASURABLY
      reaches, derived from a recorded trace. `read` is excluded because it was
      observed absent, and that exclusion has its own control.
    * The sync and close substeps are driven through the compiled arity-3
      seam, including the combined failure whose close reason the previous shape
      discarded.

  ## What the passing tally does and does not establish

  A green suite here is test evidence only. Mutation discrimination requires
  separately retained provenance, mutant bytes and results, not just a passing
  tally. Attribution strength depends on which assertion detects each changed
  implementation; a call-sequence failure alone does not prove resource cleanup.

  ## The owned-resource evidence, and exactly how far it reaches

  Descriptor reclamation IS now observed here, on this platform, for both owned
  resources: a temporary file and a synced directory. Each case opens a real
  descriptor through the product's own backend body, observes it present while
  the owner holds it, joins the owner's normal DOWN, and observes it absent
  afterwards, with the raw term retained in a surviving observer's explicit state
  and read back after that census.

  The census itself is treated as a check that can be wrong, because it was, four
  separate times: it discarded lsof's exit status and substring-matched lines, so
  a FAILED census returned zero; it accepted a status-zero response whose bytes
  were empty or unusable; it accepted a PREFIX of a record as a complete
  observation; and it inferred completeness from splitting, so a final field that
  never received its terminator parsed as complete. Every one of those turned
  truncation or failure into successful absence.

  It now returns `{:ok, count}` or `{:error, reason}` - uncertainty is never zero
  - and carries its own controls in the descriptor-census describe block, each
  paired with a retained mutant that makes it fail.

  Absence is only ever asserted AFTER a joined DOWN. Neither the reply nor
  elapsed time is the reclamation join. The adverse direction is a separate row
  that observes the descriptor STILL OPEN while the owner lingers, and it carries
  no DOWN assertion: a row that waited on DOWN first would fail on termination
  before reaching the census, which is precisely how an earlier revision
  mis-attributed a linger mutant's failure as descriptor evidence.

  ## Still not established here

  macOS and Linux require separate qualification. The census resolves its tool
  through the platform toolchain rather than a hardcoded path. A finite number
  of observations is not a universal determinism theorem,
  and no before-reply, before-return or hard-time reclamation guarantee is
  claimed. Mutation specificity beyond the rows recorded in each mutant's
  provenance is uncharacterised. Supervised restart is recorded as the selected
  existing behaviour: a default permanent child_spec can restart a DIFFERENT
  owner, and nothing here claims the global service stays stopped.
  """

  use ExUnit.Case, async: true

  alias AiPair.PaneIntentStore
  alias AiPair.Test.PaneIntentFaultFs, as: FaultFs
  alias AiPair.Test.PaneIntentScriptedBackend, as: ScriptedBackend

  @pane_1 "%1"
  @pane_2 "%2"
  # Pane ten sorts before pane eight in binary order. r3 promises lexicographic
  # binary order and explicitly does not promise decimal order, so these two ids
  # are what make the ordering clause falsifiable. Written in words here to keep
  # a redaction capture out of a comment: only the attributes below need entries.
  @pane_8 "%8"
  @pane_10 "%10"

  setup do
    root = Path.join(canonical_tmp(), "ai_pair_intent_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    assert symlink_ancestors(root) == [],
           "a symlink component would be refused before the target check"

    assert mode_of(root) == 0o700, "an unsafe root would be refused before the target check"

    {:ok, root: root}
  end

  # ============================================================ oracle controls

  describe "oracle controls: the transaction verifier" do
    test "ACCEPTS the valid newly-created-state transaction" do
      assert durable_write_ok?(valid_records(), pinned(true))
    end

    test "ACCEPTS an existing-state transaction that has no root sync" do
      assert durable_write_ok?(existing_state_records(), pinned(false))
    end

    test "REJECTS an omitted root sync when the state directory is newly created" do
      refute durable_write_ok?(omitted_root_sync(), pinned(true))
    end

    test "REJECTS a file_sync on a descriptor other than the opened one" do
      refute durable_write_ok?(wrong_synced_fd(), pinned(true))
    end

    test "REJECTS a rename to a destination other than the final path" do
      refute durable_write_ok?(wrong_rename_target(), pinned(true))
    end

    test "REJECTS directory syncs on unrelated directories" do
      refute durable_write_ok?(wrong_synced_directories(), pinned(true))
    end

    test "REJECTS a rename that precedes the file sync" do
      refute durable_write_ok?(rename_before_fsync(), pinned(true))
    end

    test "REJECTS effects that were refused rather than performed" do
      refute durable_write_ok?(refused_rename(), pinned(true))
    end

    # New counterexamples from the independent review.
    test "REJECTS a nil file_sync return, because success has an exact shape" do
      refute durable_write_ok?(nil_sync_result(), pinned(true)),
             "any-non-error was a success test that could not fail for a wrong shape"
    end

    test "REJECTS a later write left unsynced before close and rename" do
      refute durable_write_ok?(unsynced_later_write(), pinned(true)),
             "matching one ordered subsequence let final content go to disk unsynced"
    end

    test "REJECTS a file_sync attempted before the write returned" do
      refute durable_write_ok?(sync_attempted_before_write_returned(), pinned(true)),
             "attempt-ordered views lose completion position; edges need result-before-attempt"
    end

    test "REJECTS an unresolved effect anywhere in the transaction" do
      refute durable_write_ok?(unresolved_write(), pinned(true))
    end

    # C1-C3 distinguish valid spacing from additional unsynced writes.

    test "ACCEPTS the valid transaction when positions are widened" do
      assert durable_write_ok?(spaced_records(), pinned(true)),
             "spacing must not change acceptance; it only makes room for insertions"
    end

    test "C1 REJECTS a partial write that overlaps the sync and completes after it" do
      refute durable_write_ok?(partial_write_overlapping_sync(), pinned(true)),
             "a failed write can still have performed part of its effect"
    end

    test "C1 REJECTS a partial write error sequentially before the sync" do
      refute durable_write_ok?(partial_write_before_sync(), pinned(true)),
             "filtering failed writes out of the transaction is not checking all content"
    end

    test "C3 ACCEPTS a harmless extra state sync before open" do
      assert durable_write_ok?(extra_state_sync_before_open(), pinned(true)),
             "selection must be by phase; frozen r3 forbids no such extra sync"
    end
  end

  describe "oracle controls: identity is pinned, not adopted" do
    test "a temp outside the state directory is REFUSED, not adopted as the expectation" do
      assert adopt_temp(outside_state_temp(), pinned(true)) == :error,
             "adopting the observed path made the checker approve a same-directory violation"

      refute durable_write_ok?(outside_state_temp(), pinned(true))
    end

    test "a temp equal to the final path is refused" do
      assert adopt_temp(temp_equals_final(), pinned(true)) == :error
    end

    test "the valid temp is adopted with its correlated descriptor" do
      assert {:ok, tmp, :fd1} = adopt_temp(valid_records(), pinned(true))
      assert Path.dirname(tmp) == pinned(true).state
    end
  end

  describe "oracle controls: the privacy predicates" do
    test "temp privacy ACCEPTS the valid sequence and REJECTS a wrong mode" do
      assert temp_privacy_ok?(valid_records(), pinned(true))
      refute temp_privacy_ok?(wrong_temp_mode(), pinned(true)), "0777 is not private"
    end

    test "temp privacy REJECTS an omitted temporary chmod" do
      refute temp_privacy_ok?(missing_temp_chmod(), pinned(true))
    end

    test "state privacy ACCEPTS the valid sequence and REJECTS a chmod on another path" do
      assert state_privacy_ok?(valid_records(), pinned(true))
      refute state_privacy_ok?(wrong_state_chmod_path(), pinned(true))
    end

    test "state privacy REJECTS content created before the directory is private" do
      refute state_privacy_ok?(create_before_state_chmod(), pinned(true))
    end

    # C2 rejects disclosure windows even if the original mode is restored later.

    test "C2 temp privacy REJECTS an unsafe window that is later restored" do
      refute temp_privacy_ok?(temp_unsafe_during_write(), pinned(true)),
             "0600 then 0777 then content then 0600 discloses every byte written; " <>
               "an earlier private chmod does not prove privacy during content"
    end

    test "C2 state privacy REJECTS an unsafe window that is later restored" do
      refute state_privacy_ok?(state_unsafe_during_content(), pinned(true)),
             "a final safe mode cannot repair a disclosure window during content"
    end

    test "privacy predicates still ACCEPT the widened valid transaction" do
      assert temp_privacy_ok?(spaced_records(), pinned(true))
      assert state_privacy_ok?(spaced_records(), pinned(true))
    end

    # D1 checks the interval between content operations, not just each operation.

    test "D1 temp privacy REJECTS a window opened between content operations" do
      refute temp_privacy_ok?(temp_unsafe_between_operations(), pinned(true)),
             "once the write has returned the temporary already holds the bytes, so " <>
               "loosening the mode after it and restoring before the next operation " <>
               "discloses file content; no further content operation is needed"
    end

    test "D1 state privacy REJECTS a window opened between content operations" do
      refute state_privacy_ok?(state_unsafe_between_operations(), pinned(true)),
             "0777 on the state directory exposes its entries and directory write " <>
               "access; it does not override the file's own 0600, and it is still a " <>
               "violation of the private state requirement"
    end

    test "D1 privacy follows the file to its final path through publication" do
      refute temp_privacy_ok?(final_unsafe_after_rename(), pinned(true)),
             "the same bytes live at the final path once the rename returns; a mode " <>
               "loosened there and restored before the transaction ends is invisible " <>
               "to a temp-only window and to a final-mode assertion"
    end

    # Boundary being asserted explicitly rather than left implied: under frozen r3
    # a permission window is an S1-F1-06 privacy defect, not an S1-F1-07 durability
    # defect. All three D1 schedules therefore remain durable. Flagged for the
    # reviewer to confirm or reject.
    test "the D1 schedules stay durable: privacy and durability are separate" do
      i = pinned(true)
      assert durable_write_ok?(temp_unsafe_between_operations(), i)
      assert durable_write_ok?(state_unsafe_between_operations(), i)
      assert durable_write_ok?(final_unsafe_after_rename(), i)
    end

    # The temporary-file interval starts before an in-flight write returns;
    # the state-directory interval spans the whole transaction.

    test "D1 temp privacy REJECTS an unsafe window inside an in-flight write" do
      refute temp_privacy_ok?(temp_unsafe_during_inflight_write(), pinned(true)),
             "a write can perform part of its effect before the callback returns, " <>
               "so the owned-file interval must begin at temporary creation; a " <>
               "window opened after the write's attempt and closed before its " <>
               "result falls between an attempt-sampled check and a result-started one"
    end

    test "D1 state privacy REJECTS an in-flight window, as its whole-transaction span already did" do
      refute state_privacy_ok?(state_unsafe_during_inflight_write(), pinned(true)),
             "the state window spans the whole transaction, so this was already " <>
               "rejected before the correction; asserted here so the coverage is " <>
               "measured rather than assumed"
    end

    # The owned-file interval ends at the observed call endpoint, not its sync.

    test "D1 temp privacy REJECTS a final-path window after the sync but before the call returns" do
      refute temp_privacy_ok?(final_unsafe_after_sync(), pinned(true)),
             "the qualifying directory sync is a durability milestone, not the API " <>
               "return; the published file still holds the bytes until the call ends"
    end

    test "D1 state privacy REJECTS a state window after the sync but before the call returns" do
      refute state_privacy_ok?(state_unsafe_after_sync(), pinned(true)),
             "directory entries and directory write access stay exposed for the " <>
               "remainder of the observed call"
    end

    test "a harmless private final chmod after the sync is still ACCEPTED" do
      i = pinned(true)
      assert temp_privacy_ok?(harmless_private_final_chmod_after_sync(), i)
      assert state_privacy_ok?(harmless_private_final_chmod_after_sync(), i)
    end
  end

  # ============================================================ double controls
  # Driven by a scripted backend so none of them depends on SystemFs being absent.

  # The resource oracle is itself a check that can be wrong, so it gets its own
  # controls. These drive the census with SCRIPTED output rather than a live
  # lsof, so each row states exactly which way the oracle must be able to fail.
  describe "oracle controls: the descriptor census" do
    @census_dir "/owned/inert/state"

    test "a numeric descriptor on the exact target is counted" do
      assert {:ok, 1} = dir_fd_census(@census_dir, field_census("f25\nn#{@census_dir}\n"))
    end

    test "a failed census is an ERROR, never zero descriptors" do
      assert {:error, {:census_exit_status, 1}} =
               dir_fd_census(@census_dir, field_census("f25\nn#{@census_dir}\n", 1)),
             "a census that could not be taken must not read as successful reclamation"
    end

    test "an unavailable or timed-out census tool is an ERROR" do
      assert {:error, :census_tool_unavailable} =
               dir_fd_census(@census_dir, fn -> {:error, :census_tool_unavailable} end)

      assert {:error, {:census_timed_out, 1234, {:joined, 1234}}} =
               dir_fd_census(@census_dir, fn ->
                 {:error, {:census_timed_out, 1234, {:joined, 1234}}}
               end)
    end

    # The previous malformed control supplied an invalid OUTER term, so it never
    # exercised the path that matters: a SUCCESSFUL command whose bytes are
    # unusable. That path silently returned zero.
    test "malformed bytes with a SUCCESS status are an ERROR, not absence" do
      assert {:error, {:census_malformed, _}} =
               dir_fd_census(@census_dir, fn -> {"this is not field output\n", 0} end),
             "status-zero unusable bytes were previously counted as zero descriptors"
    end

    test "empty bytes with a SUCCESS status are an ERROR, not absence" do
      assert {:error, :census_empty} = dir_fd_census(@census_dir, fn -> {"", 0} end)
    end

    test "an invalid outer term is still an ERROR" do
      assert {:error, {:census_unparseable, :garbage}} =
               dir_fd_census(@census_dir, fn -> :garbage end)
    end

    test "output from an unexpected process is an ERROR" do
      # :os.getpid/0 returns a CHARLIST, not an integer - arithmetic on it raises.
      other = "1" <> to_string(:os.getpid())
      census = fn -> {"p#{other}\nf25\nn#{@census_dir}\n", 0} end

      assert {:error, {:census_wrong_process, ^other}} = dir_fd_census(@census_dir, census),
             "the census must be bound to the process it claims to describe"
    end

    test "a name record with no preceding descriptor is an ERROR" do
      assert {:error, {:census_malformed, :name_without_descriptor}} =
               dir_fd_census(@census_dir, field_census("n#{@census_dir}\n"))
    end

    test "a prefix neighbour is not this directory's descriptor" do
      assert {:ok, 0} = dir_fd_census(@census_dir, field_census("f25\nn#{@census_dir}-other\n")),
             "NAME must match exactly; a substring match would count a neighbour"
    end

    test "a cwd record is not an opened numeric descriptor" do
      assert {:ok, 0} = dir_fd_census(@census_dir, field_census("fcwd\nn#{@census_dir}\n")),
             "only a NUMERIC descriptor is an open descriptor"
    end

    # The unlinked case, in its DELETED reporting form. This row is scripted, and
    # it covers platforms that append "(deleted)" to the name of an unlinked but
    # still-open file.
    #
    # It is not the platform's own behaviour here: macOS lsof was measured
    # reporting such a descriptor under its plain resolved pathname, unchanged by
    # the unlink. So this row is portability coverage, and the LIVE unlinked
    # evidence comes from the plain-path branch instead. Saying so matters -
    # otherwise a scripted row would be read as proof of platform behaviour it
    # never exercised.
    test "an unlinked but still-open descriptor is NOT absence" do
      census = field_census("f25\nn#{@census_dir} (deleted)\n")

      assert {:ok, 1} = dir_fd_census(@census_dir, census),
             "an unlinked owned descriptor is the same resource, not a reclaimed one"
    end

    # A1: a PREFIX of a record is not a complete census. Each of these returned
    # {:ok, 0} before, so truncated output read as absence.
    test "a trailing descriptor with no name is an ERROR" do
      assert {:error, {:census_incomplete, _}} = dir_fd_census(@census_dir, field_census("f25\n"))
    end

    test "a descriptor overwritten before its name is an ERROR" do
      assert {:error, {:census_incomplete, _}} =
               dir_fd_census(@census_dir, field_census("f25\nf26\nn/other\n")),
             "silently dropping the first descriptor loses an owned resource"
    end

    test "an empty descriptor payload is an ERROR" do
      assert {:error, {:census_malformed, :empty_descriptor}} =
               dir_fd_census(@census_dir, field_census("f\nn#{@census_dir}\n"))
    end

    test "an empty name payload is an ERROR" do
      assert {:error, {:census_malformed, :empty_name}} =
               dir_fd_census(@census_dir, field_census("f25\nn\n"))
    end

    # A2: a correct leading header must not authorise later foreign records.
    test "a LATER foreign process record is an ERROR" do
      other = "1" <> to_string(:os.getpid())

      census = fn ->
        {"p#{:os.getpid()}\nf25\nn/elsewhere\np#{other}\nf26\nn#{@census_dir}\n", 0}
      end

      assert {:error, {:census_wrong_process, ^other}} = dir_fd_census(@census_dir, census),
             "the descriptor after a foreign header belongs to another process"
    end

    # A3: pseudo descriptors are classified, so a bad token cannot hide as one.
    test "an unknown non-numeric descriptor token is an ERROR, not a pseudo record" do
      assert {:error, {:census_malformed, {:unsupported_descriptor, "bogus"}}} =
               dir_fd_census(@census_dir, field_census("fbogus\nn#{@census_dir}\n"))
    end

    test "supported pseudo descriptors are classified and not counted" do
      assert {:ok, 0} = dir_fd_census(@census_dir, field_census("ftxt\nn#{@census_dir}\n"))
      assert {:ok, 0} = dir_fd_census(@census_dir, field_census("frtd\nn#{@census_dir}\n"))
    end

    # B1: the join must separate confirmed absence from an unanswerable query.
    # These drive await_os_absence directly with an injected query, so no signal
    # is ever issued to the inert pid used as test data.
    test "a failed existence QUERY is uncertainty, not confirmed absence" do
      denied = fn _pid -> {"kill: 4321: Operation not permitted\n", 1} end
      deadline = System.monotonic_time(:millisecond) + 50

      assert {:unknown, 4321, _reason} = await_os_absence(4321, deadline, denied),
             "a query that could not answer must never certify absence"
    end

    test "a no-such-process answer IS confirmed absence" do
      gone = fn _pid -> {"kill: 4321: No such process\n", 1} end
      deadline = System.monotonic_time(:millisecond) + 50

      assert {:joined, 4321} = await_os_absence(4321, deadline, gone)
    end

    test "a still-live process within the deadline is not joined" do
      alive = fn _pid -> {"", 0} end
      deadline = System.monotonic_time(:millisecond) + 30

      assert {:not_joined, 4321} = await_os_absence(4321, deadline, alive)
    end

    # The framing witness. Splitting discards the terminator, so a final field
    # that never arrived complete looked like a complete non-match and returned
    # {:ok, 0}. Truncation must never be reported as absence.
    test "an unterminated final name is INCOMPLETE, not a no-match" do
      census = fn -> {"p#{:os.getpid()}\nf25\nn/owned/inert/tar", 0} end

      assert {:error, {:census_incomplete, :unterminated_final_field}} =
               dir_fd_census("/owned/inert/target", census),
             "a truncated target name must not become a complete no-match witness"
    end

    # The neighbour that keeps the guard honest: the SAME bytes, correctly
    # terminated, must still be a legitimate zero. Without this row the guard
    # could be satisfied by rejecting everything.
    test "the same record correctly terminated is a valid no-match" do
      census = fn -> {"p#{:os.getpid()}\nf25\nn/owned/inert/tar\n", 0} end

      assert {:ok, 0} = dir_fd_census("/owned/inert/target", census),
             "the framing guard must not weaken complete-no-match behaviour"
    end

    test "a well-formed complete census with no matching resource may report zero" do
      assert {:ok, 0} = dir_fd_census(@census_dir, field_census("f25\nn/somewhere/else\n")),
             "legitimate absence must still be expressible, or the oracle is useless"
    end

    test "several genuine descriptors on the target are all counted" do
      census =
        field_census("f25\nn#{@census_dir}\nf26\nn#{@census_dir}\nfcwd\nn#{@census_dir}\n")

      assert {:ok, 2} = dir_fd_census(@census_dir, census)
    end

    # B. A killed BEAM Task does not terminate the OS command it spawned: the
    # reviewer demonstrated a child completing its work AFTER the census had
    # already reported a timeout. A precomputed :census_timed_out value cannot
    # prove the runner's lifecycle, so this drives the REAL wrapper against an
    # owned adverse command and joins the child's termination.
    test "the census timeout terminates its owned OS child and CONFIRMS absence" do
      dir = Path.join(System.tmp_dir!(), "census_child_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      marker = Path.join(dir, "completed")
      script = Path.join(dir, "adverse.py")

      # A TRULY single-process adverse command. The previous fixture was a shell
      # running `sleep`, which forks a descendant - so joining the shell left the
      # sleeper alive, and the reviewer demonstrated exactly that with an owned
      # launcher/child pair. This process does its own waiting and forks nothing,
      # which keeps the direct-child contract honest without inventing any
      # process-tree behaviour in the product.
      python = System.find_executable("python3")
      assert python, "precondition: python3 is required for the single-process fixture"

      File.write!(
        script,
        "#!#{python}\nimport time\ntime.sleep(1.0)\nopen(#{inspect(marker)}, 'w').write('x')\n"
      )

      File.chmod!(script, 0o700)

      assert {:error, {:census_timed_out, os_pid, join}} = run_bounded_census(script, [], 40)
      assert is_integer(os_pid), "the owned child's OS pid must be observable to be joined"

      assert {:joined, ^os_pid} = join,
             "absence must be CONFIRMED by signal-zero, not assumed from sending a signal"

      # Wait PAST the command's scheduled effect. The previous revision waited
      # 300ms for a marker scheduled at 2s, so the marker was absent whether or
      # not the child survived - it could not fail for the defect it names.
      Process.sleep(1_400)

      refute File.exists?(marker),
             "a joined child must never reach its scheduled work, and this waits past it"
    end
  end

  describe "the fault double records what effects actually did" do
    test "a pass-through call reaches the backend and records its return" do
      {fs, be} = scripted_fs()
      {_mod, agent} = fs
      ScriptedBackend.script(be, :lstat, {:return, {:ok, %{type: :directory, mode: 0o700}}})

      assert {:ok, %{mode: 0o700}} = FaultFs.lstat(agent, "/owned/root")
      assert {:lstat, ["/owned/root"], :invoked, {:ok, _}} = List.last(FaultFs.effects(fs))
      assert [{:lstat, ["/owned/root"]}] = ScriptedBackend.calls(be)
    end

    test "a raising callback records :raised whether or not a real backend exists" do
      {fs, be} = scripted_fs()
      {_mod, agent} = fs
      ScriptedBackend.script(be, :mkdir, {:raise, RuntimeError.exception("scripted failure")})

      assert_raise RuntimeError, "scripted failure", fn -> FaultFs.mkdir(agent, "/owned/state") end
      assert {:mkdir, _, :raised, _} = List.last(FaultFs.effects(fs))
    end

    test "an injected hook runs the hook AND the backend, and records the fault fired" do
      {fs, be} = scripted_fs()
      {_mod, agent} = fs
      parent = self()
      FaultFs.inject(fs, :chmod, 1, {:hook, fn -> send(parent, :hook_ran) end})
      ScriptedBackend.script(be, :chmod, {:return, :ok})

      assert :ok = FaultFs.chmod(agent, "/owned/state", 0o700)
      assert_receive :hook_ran, 1_000

      assert {:chmod, _, :invoked, :ok} = List.last(FaultFs.effects(fs)),
             "a hook is a scheduling hook, not a refusal"

      assert FaultFs.fault_fired?(fs, :chmod, fn [p, _] -> p == "/owned/state" end)
      assert [{:chmod, ["/owned/state", 0o700]}] = ScriptedBackend.calls(be)
    end

    test "a short-circuit refusal never enters the backend" do
      {fs, be} = scripted_fs()
      {_mod, agent} = fs
      FaultFs.inject(fs, :rename, 1, {:error, :eio})

      assert {:error, :eio} = FaultFs.rename(agent, "/a", "/b")
      assert {:rename, _, :refused, {:error, :eio}} = List.last(FaultFs.effects(fs))

      assert ScriptedBackend.calls(be) == [],
             "non-entry is proven by the backend's own record, not inferred from a label"
    end

    test "every attempt resolves to a disposition, including raising paths" do
      {fs, _be} = scripted_fs()
      {_mod, agent} = fs
      FaultFs.inject(fs, :close, 1, {:hook, fn -> raise "hook exploded" end})

      assert_raise RuntimeError, "hook exploded", fn -> FaultFs.close(agent, :fd) end

      refute Enum.any?(FaultFs.timeline(fs), &(&1.disposition == :unresolved))
    end

    test "a callback attempted after halt is still traced and counted" do
      {fs, _be} = scripted_fs()
      {_mod, agent} = fs
      FaultFs.inject(fs, :write, 1, :halt)

      assert {:error, :halted} = FaultFs.write(agent, :fd, "x")
      assert {:error, :halted} = FaultFs.close(agent, :fd)

      assert :close in FaultFs.ops(fs)
      assert FaultFs.count(fs, :close) == 1
    end

    test "timeline carries positions that the attempt-ordered view cannot" do
      {fs, be} = scripted_fs()
      {_mod, agent} = fs
      ScriptedBackend.script(be, :lstat, {:return, {:ok, %{}}})
      _ = FaultFs.lstat(agent, "/owned/root")

      assert [%{attempt_at: a, result_at: r}] = FaultFs.timeline(fs)
      assert is_integer(a) and is_integer(r) and r > a
    end
  end

  # ============================================================ S1-F1-11

  describe "S1-F1-11 owned fixtures are reclaimed" do
    test "a tracer whose owner raises is torn down, observed from a surviving observer" do
      {owner, agent} = spawn_barriered_owner!()

      owner_ref = Process.monitor(owner)
      tracer_ref = Process.monitor(agent)
      send(owner, :fail_now)

      assert_receive {:DOWN, ^owner_ref, :process, ^owner, {%RuntimeError{}, _}}, 1_000
      assert_receive {:DOWN, ^tracer_ref, :process, ^agent, reason}, 1_000

      refute reason == :noproc, "a :noproc DOWN would mean the tracer died before we watched it"
      refute Process.alive?(agent)
    end

    # This establishes reclamation of helpers still blocked at the barrier.
    # It does not force observer failure or establish exceptional cleanup.
    test "blocked helpers can be reclaimed and joined while still at the barrier" do
      {owner, agent} = spawn_barriered_owner!()

      assert Process.alive?(owner) and Process.alive?(agent),
             "precondition: both helpers are blocked and alive"

      assert reclaim_helper!(owner, agent) == :ok
      refute Process.alive?(owner)
      refute Process.alive?(agent)
    end

    test "stopping an owned tracer twice is safe" do
      fs = FaultFs.new()
      assert FaultFs.stop(fs) == :ok
      assert FaultFs.stop(fs) == :ok
    end

    # Owned-FD lifecycle, exercised on a FAILING transaction rather than the happy
    # path: a descriptor leaked on the error route is the one that actually leaks.
    # The witness comes from the callee's own trace, not from the store claiming
    # it cleaned up.
    test "every temporary descriptor the store opens is closed, including on failure",
         %{root: root} do
      fs = new_fs()
      FaultFs.inject(fs, :write, 1, {:error, :enospc})
      {:ok, store} = PaneIntentStore.start_link(root: root, fs: fs)

      assert {:error, %{stage: :write}} = PaneIntentStore.put(store, record(@pane_1, root))

      records = FaultFs.timeline(fs)

      opened =
        for r <- records, r.op == :open_exclusive, match?({:ok, _}, r.value), do: elem(r.value, 1)

      closed = for r <- records, r.op == :close, r.args != [], do: hd(r.args)

      assert opened != [], "precondition: the transaction must have opened a descriptor"

      assert Enum.all?(opened, &(&1 in closed)),
             "an owned descriptor was never closed: opened #{inspect(opened)}, " <>
               "closed #{inspect(closed)}"
    end
  end

  # ============================================================ S1-F1-01

  describe "S1-F1-01 one owner per canonical root" do
    test "independent roots each get a live owner", %{root: root} do
      other = Path.join(canonical_tmp(), "ai_pair_intent_#{System.unique_integer([:positive])}")
      File.mkdir_p!(other)
      File.chmod!(other, 0o700)
      on_exit(fn -> File.rm_rf!(other) end)

      assert {:ok, a} = PaneIntentStore.start_link(root: root)
      assert {:ok, b} = PaneIntentStore.start_link(root: other)
      assert a != b
    end

    test "a second owner of the same root refuses", %{root: root} do
      assert {:ok, _first} = PaneIntentStore.start_link(root: root)
      assert {:error, %{stage: :ownership}} = PaneIntentStore.start_link(root: root)
    end

    test "a dot-component alias of the same root refuses, and never reaches the seam",
         %{root: root} do
      alias_root = Path.join([root, "..", Path.basename(root)])
      fs = new_fs()

      assert {:ok, _first} = PaneIntentStore.start_link(root: root)
      assert {:error, %{stage: :ownership}} = PaneIntentStore.start_link(root: alias_root, fs: fs)

      assert FaultFs.effects(fs) == []
    end

    # G1. Observing that nobody holds the name is not claiming it. Under the
    # earlier check-then-register ordering both starters passed the check and
    # both read, and the loser's stale snapshot later overwrote an acknowledged
    # update. Ownership is now held from init, so a competitor is refused while
    # the first owner is still loading - and refused before touching its seam.
    test "a competitor is refused while another owner is still completing startup",
         %{root: root} do
      {:ok, seed} = PaneIntentStore.start_link(root: root)
      :ok = PaneIntentStore.put(seed, record(@pane_1, root))
      stop_and_join!(seed)

      test_pid = self()
      holder_fs = new_fs()

      FaultFs.inject(
        holder_fs,
        :read,
        1,
        {:hook,
         fn ->
           send(test_pid, {:inside_startup_read, self()})

           receive do
             :release -> :ok
           after
             5_000 -> :ok
           end
         end}
      )

      holder = Task.async(fn -> PaneIntentStore.start_link(root: root, fs: holder_fs) end)
      assert_receive {:inside_startup_read, owner}, 2_000

      competitor_fs = new_fs()

      assert {:error, %{stage: :ownership}} =
               PaneIntentStore.start_link(root: root, fs: competitor_fs)

      assert FaultFs.effects(competitor_fs) == [],
             "the refused starter must not reach the seam, so it can hold no snapshot to resurrect"

      send(owner, :release)
      assert {:ok, _pid} = Task.await(holder, 5_000)
    end

    # The registered pid IS discoverable before start_link returns. A caller that
    # finds it must never be handed a healthy empty view of an unloaded store.
    test "an owner discovered during startup never serves a healthy empty snapshot",
         %{root: root} do
      {:ok, seed} = PaneIntentStore.start_link(root: root)
      :ok = PaneIntentStore.put(seed, record(@pane_1, root))
      stop_and_join!(seed)

      test_pid = self()
      fs = new_fs()

      FaultFs.inject(
        fs,
        :read,
        1,
        {:hook,
         fn ->
           send(test_pid, {:inside_startup_read, self()})

           receive do
             :release -> :ok
           after
             5_000 -> :ok
           end
         end}
      )

      holder = Task.async(fn -> PaneIntentStore.start_link(root: root, fs: fs) end)
      assert_receive {:inside_startup_read, owner}, 2_000

      assert :global.whereis_name({PaneIntentStore, root}) == owner,
             "precondition: the owner is discoverable by name before startup completes"

      early = Task.async(fn -> PaneIntentStore.list(owner) end)
      send(owner, :release)

      assert {:ok, _pid} = Task.await(holder, 5_000)

      assert {:ok, [only]} = Task.await(early, 5_000)

      assert only["pane_id"] == @pane_1,
             "a caller that discovered the owner mid-startup must see the loaded snapshot, never []"
    end

    # Caller death DURING startup. The owner is blocked inside :complete_startup,
    # so a killed starter must take it down through the start_link link and
    # release the owned name; a half-started owner must never be left registered.
    test "a starter killed during startup releases the owned name", %{root: root} do
      {:ok, seed} = PaneIntentStore.start_link(root: root)
      :ok = PaneIntentStore.put(seed, record(@pane_1, root))
      stop_and_join!(seed)

      test_pid = self()
      fs = new_fs()

      FaultFs.inject(
        fs,
        :read,
        1,
        {:hook,
         fn ->
           send(test_pid, {:inside_startup_read, self()})

           receive do
             :never -> :ok
           after
             5_000 -> :ok
           end
         end}
      )

      starter = spawn(fn -> PaneIntentStore.start_link(root: root, fs: fs) end)
      assert_receive {:inside_startup_read, owner}, 2_000

      owner_ref = Process.monitor(owner)
      Process.exit(starter, :kill)

      assert_receive {:DOWN, ^owner_ref, :process, ^owner, _},
                     5_000,
                     "the half-started owner must not survive its killed starter"

      {:ok, next} = restart_owner!(root)
      assert {:ok, [only]} = PaneIntentStore.list(next)
      assert only["pane_id"] == @pane_1
    end

    # Documented behaviour, flagged for the reviewer rather than assumed.
    # start_link links, and a linked process exiting NORMALLY does not take the
    # owner with it, so an owner outlives a caller that simply returns. That is
    # ordinary OTP lifetime and is not a leak: the owner is still a real,
    # registered, working owner of that root, reachable by name, and refusing a
    # second starter is then correct rather than a stale-name bug. Recorded as a
    # control so the semantics cannot change silently. If the reviewer rules that
    # an owner must not outlive its starter, this test is what changes.
    test "an owner survives a starter that exits normally, and still owns the root",
         %{root: root} do
      test_pid = self()

      caller =
        spawn(fn ->
          {:ok, pid} = PaneIntentStore.start_link(root: root)
          send(test_pid, {:started, pid})

          receive do
            :finish -> :ok
          after
            5_000 -> :ok
          end
        end)

      assert_receive {:started, owner}, 2_000
      ref = Process.monitor(caller)
      send(caller, :finish)
      assert_receive {:DOWN, ^ref, :process, ^caller, :normal}, 2_000

      assert Process.alive?(owner), "a normal caller exit does not terminate a linked owner"
      assert :global.whereis_name({PaneIntentStore, root}) == owner
      assert {:ok, []} = PaneIntentStore.list(owner)

      assert {:error, %{stage: :ownership}} = PaneIntentStore.start_link(root: root),
             "the surviving owner still holds the root, so a second starter is correctly refused"

      stop_and_join!(owner)
    end
  end

  # ============================================================ S1-F1-02

  describe "S1-F1-02 writes serialize without loss" do
    test "smoke: two different-pane puts both survive reload", %{root: root} do
      {:ok, store} = PaneIntentStore.start_link(root: root)
      parent = self()

      writers =
        for pane <- [@pane_1, @pane_2] do
          Task.async(fn ->
            send(parent, {:ready, self()})
            receive do: (:go -> :ok)
            PaneIntentStore.put(store, record(pane, root))
          end)
        end

      for task <- writers do
        pid = task.pid
        assert_receive {:ready, ^pid}, 1_000
      end

      for task <- writers, do: send(task.pid, :go)
      for task <- writers, do: assert(:ok = Task.await(task, 5_000))

      stop_and_join!(store)
      {:ok, reloaded} = PaneIntentStore.start_link(root: root)

      assert {:ok, records} = PaneIntentStore.list(reloaded)
      assert Enum.map(records, & &1["pane_id"]) == [@pane_1, @pane_2]
    end

    test "same-pane sequential replacement keeps the last write", %{root: root} do
      {:ok, store} = PaneIntentStore.start_link(root: root)

      assert :ok = PaneIntentStore.put(store, record(@pane_1, root, %{"command" => "first"}))
      assert :ok = PaneIntentStore.put(store, record(@pane_1, root, %{"command" => "second"}))

      assert {:ok, [only]} = PaneIntentStore.list(store)
      assert only["command"] == "second"
    end

    # The frozen failure control asks for deterministic barriers, not a sleep and
    # not the smoke row above. The hook runs INSIDE the owner at the write
    # boundary, so while it is blocked the second caller's request can only be
    # queued. A read-modify-write performed outside the server would build the
    # second snapshot from a view taken before the first landed, and one record
    # would vanish; here the queue depth is observed, not waited for.
    test "a put issued while another transaction is open is serialized, not lost",
         %{root: root} do
      fs = new_fs()
      test_pid = self()

      FaultFs.inject(
        fs,
        :write,
        1,
        {:hook,
         fn ->
           send(test_pid, :inside_first_write)

           receive do
             :release -> :ok
           after
             5_000 -> :ok
           end
         end}
      )

      {:ok, store} = PaneIntentStore.start_link(root: root, fs: fs)

      first = Task.async(fn -> PaneIntentStore.put(store, record(@pane_1, root)) end)
      assert_receive :inside_first_write, 2_000

      second = Task.async(fn -> PaneIntentStore.put(store, record(@pane_2, root)) end)

      assert await_queued(store),
             "the second call must be enqueued while the first transaction is still open"

      send(store, :release)

      assert :ok = Task.await(first, 5_000)
      assert :ok = Task.await(second, 5_000)

      stop_and_join!(store)
      {:ok, reloaded} = PaneIntentStore.start_link(root: root)

      assert {:ok, records} = PaneIntentStore.list(reloaded)

      assert Enum.map(records, & &1["pane_id"]) == [@pane_1, @pane_2],
             "both writes must survive the reload; a lost update drops one"
    end
  end

  # ============================================================ S1-F1-03

  describe "S1-F1-03 round trip and empty state" do
    test "put, list, delete and restart preserve exact metadata", %{root: root} do
      {:ok, store} = PaneIntentStore.start_link(root: root)
      written = record(@pane_1, root)

      assert :ok = PaneIntentStore.put(store, written)
      assert {:ok, [read_back]} = PaneIntentStore.list(store)
      assert read_back == written

      stop_and_join!(store)
      {:ok, restarted} = PaneIntentStore.start_link(root: root)
      assert {:ok, [^written]} = PaneIntentStore.list(restarted)

      assert :ok = PaneIntentStore.delete(restarted, @pane_1)
      assert {:ok, []} = PaneIntentStore.list(restarted)
    end

    test "an absent final file is empty success", %{root: root} do
      refute File.exists?(state_path(root))
      {:ok, store} = PaneIntentStore.start_link(root: root)
      assert {:ok, []} = PaneIntentStore.list(store)
    end

    test "a read failure is an error, never empty success", %{root: root} do
      seed_state!(root, envelope(%{}))
      final = state_path(root)

      fs = new_fs()
      FaultFs.inject(fs, :read, fn [path] -> path == final end, {:error, :eacces})

      assert {:error, %{stage: :read, outcome: :unchanged}} =
               PaneIntentStore.start_link(root: root, fs: fs)

      assert FaultFs.fault_fired?(fs, :read, &(&1 == [final]))
    end

    test "malformed JSON is a visible error, never empty success", %{root: root} do
      seed_state!(root, "{not json")
      assert {:error, %{stage: :decode}} = PaneIntentStore.start_link(root: root)
    end

    test "records are returned in lexicographic binary pane_id order", %{root: root} do
      {:ok, store} = PaneIntentStore.start_link(root: root)
      assert :ok = PaneIntentStore.put(store, record(@pane_8, root))
      assert :ok = PaneIntentStore.put(store, record(@pane_10, root))

      assert {:ok, records} = PaneIntentStore.list(store)
      assert Enum.map(records, & &1["pane_id"]) == [@pane_10, @pane_8]
    end
  end

  # ============================================================ S1-F1-04

  describe "S1-F1-04 whole-envelope and whole-record validation" do
    test "an unsupported envelope version refuses", %{root: root} do
      seed_state!(
        root,
        ~s({"schema_version":"2.0","updated_at":"2026-09-11T00:00:00Z","attachments":{}})
      )

      assert {:error, %{stage: :schema}} = PaneIntentStore.start_link(root: root)
    end

    test "an attachments key that disagrees with its record pane_id refuses", %{root: root} do
      seed_state!(root, envelope(%{@pane_2 => record(@pane_1, root)}))
      assert {:error, %{stage: :schema}} = PaneIntentStore.start_link(root: root)
    end

    test "a duplicate JSON object key refuses at stage :decode", %{root: root} do
      seed_state!(
        root,
        ~s({"schema_version":"1.0","schema_version":"1.0","updated_at":"2026-09-11T00:00:00Z","attachments":{}})
      )

      assert {:error, %{stage: :decode}} = PaneIntentStore.start_link(root: root)
    end

    test "a duplicate key nested inside a record also refuses at stage :decode", %{root: root} do
      seed_state!(
        root,
        ~s({"schema_version":"1.0","updated_at":"2026-09-11T00:00:00Z","attachments":{"%1":{"pane_id":"%1","pane_id":"%1"}}})
      )

      assert {:error, %{stage: :decode}} = PaneIntentStore.start_link(root: root)
    end

    test "an unknown envelope key refuses", %{root: root} do
      seed_state!(
        root,
        ~s({"schema_version":"1.0","updated_at":"2026-09-11T00:00:00Z","attachments":{},"extra":1})
      )

      assert {:error, %{stage: :schema}} = PaneIntentStore.start_link(root: root)
    end

    test "an unknown record key refuses with no write", %{root: root} do
      {:ok, store} = PaneIntentStore.start_link(root: root)
      bad = Map.put(record(@pane_1, root), "extra", "x")

      assert {:error, %{stage: :validation}} = PaneIntentStore.put(store, bad)
      refute File.exists?(state_path(root))
    end

    test "a partial record refuses", %{root: root} do
      {:ok, store} = PaneIntentStore.start_link(root: root)

      assert {:error, %{stage: :validation}} =
               PaneIntentStore.put(store, Map.delete(record(@pane_1, root), "cwd"))
    end

    test "wrong types, bad ids, bad timestamps and bad generations refuse", %{root: root} do
      {:ok, store} = PaneIntentStore.start_link(root: root)

      for bad <- [
            record(@pane_1, root, %{"agent" => "cla\0ude"}),
            record("pane-1", root),
            record(@pane_1, root, %{"pane_pid" => 0}),
            record(@pane_1, root, %{"pane_pid" => "4242"}),
            record(@pane_1, root, %{"updated_at" => "not-a-timestamp"}),
            record(@pane_1, root, %{"session_gen" => ""}),
            record(@pane_1, root, %{"cwd" => "relative/path"})
          ] do
        assert {:error, %{stage: :validation}} = PaneIntentStore.put(store, bad)
      end
    end

    test "atom-keyed input refuses; r3 accepts string-keyed maps only", %{root: root} do
      {:ok, store} = PaneIntentStore.start_link(root: root)
      assert {:error, %{stage: :validation}} = PaneIntentStore.put(store, %{pane_id: @pane_1})
    end

    test "novel untrusted keys AND values are never interned as atoms", %{root: root} do
      novel_key = "s1_novel_key_#{System.unique_integer([:positive])}"
      novel_value = "s1_novel_value_#{System.unique_integer([:positive])}"

      seed_state!(
        root,
        envelope(%{
          @pane_1 => record(@pane_1, root, %{"agent" => novel_value}) |> Map.put(novel_key, "x")
        })
      )

      assert {:error, _} = PaneIntentStore.start_link(root: root)
      assert_raise ArgumentError, fn -> String.to_existing_atom(novel_key) end
      assert_raise ArgumentError, fn -> String.to_existing_atom(novel_value) end
    end

    # G4. The row above pairs its novel value with an unknown KEY, so exact_keys
    # rejects the map before any value validator runs: it witnesses non-interning
    # on a REJECTED path only, and a conversion restricted to accepted record
    # values passes it untouched - the reviewer demonstrated exactly that with a
    # mutant interning agent immediately after the key check. These two drive a
    # novel value through a VALID record, once via put and once via a persisted
    # load, so the accepted branch is covered on both routes into the store.
    test "a novel value in an ACCEPTED record is not interned, via put", %{root: root} do
      novel = "s1_put_novel_#{System.unique_integer([:positive])}"
      refute atom_exists?(novel), "precondition: the value must not already be an atom"

      {:ok, store} = PaneIntentStore.start_link(root: root)
      assert :ok = PaneIntentStore.put(store, record(@pane_1, root, %{"agent" => novel}))

      assert {:ok, [only]} = PaneIntentStore.list(store)
      assert only["agent"] == novel

      refute atom_exists?(novel),
             "an ACCEPTED record's novel value must not be interned; the earlier witness " <>
               "only covers values on records rejected at the key check"
    end

    test "a novel value in an ACCEPTED persisted record is not interned on load",
         %{root: root} do
      novel = "s1_load_novel_#{System.unique_integer([:positive])}"
      refute atom_exists?(novel), "precondition: the value must not already be an atom"

      seed_state!(root, envelope(%{@pane_1 => record(@pane_1, root, %{"agent" => novel})}))

      {:ok, store} = PaneIntentStore.start_link(root: root)
      assert {:ok, [only]} = PaneIntentStore.list(store)
      assert only["agent"] == novel

      refute atom_exists?(novel),
             "a validated value read from an untrusted file must not be interned"
    end
  end

  # ============================================================ S1-F1-05

  describe "S1-F1-05 only explicit private contained paths are used" do
    test "a relative root refuses" do
      assert {:error, %{stage: :path}} = PaneIntentStore.start_link(root: "relative/root")
    end

    test "a root with a symlink component refuses", %{root: root} do
      link = Path.join(canonical_tmp(), "ai_pair_link_#{System.unique_integer([:positive])}")
      File.ln_s!(root, link)
      on_exit(fn -> File.rm_rf!(link) end)
      assert symlink_ancestors(link) != []

      assert {:error, %{stage: :path}} = PaneIntentStore.start_link(root: link)
    end

    test "a symlinked state directory refuses", %{root: root} do
      outside = Path.join(canonical_tmp(), "ai_pair_outside_#{System.unique_integer([:positive])}")
      File.mkdir_p!(outside)
      File.chmod!(outside, 0o700)
      on_exit(fn -> File.rm_rf!(outside) end)
      File.ln_s!(outside, Path.join(root, "state"))

      assert {:error, %{stage: :path}} = PaneIntentStore.start_link(root: root)
    end

    test "an existing state directory with a disallowed mode refuses at :permission",
         %{root: root} do
      state = Path.join(root, "state")
      File.mkdir_p!(state)
      File.chmod!(state, 0o755)
      assert mode_of(state) == 0o755

      assert {:error, %{stage: :permission}} = PaneIntentStore.start_link(root: root)
      assert mode_of(state) == 0o755, "the store must not have repaired the directory"
    end

    test "a failed lstat refuses at :path with its underlying reason", %{root: root} do
      fs = new_fs()
      FaultFs.inject(fs, :lstat, 1, {:error, :eio})

      assert {:error, %{stage: :path, reason: reason}} =
               PaneIntentStore.start_link(root: root, fs: fs)

      assert FaultFs.fault_fired?(fs, :lstat, fn _ -> true end)
      refute is_nil(reason)
    end

    test "a record's own path fields cannot redirect the write", %{root: root} do
      elsewhere =
        Path.join(canonical_tmp(), "ai_pair_elsewhere_#{System.unique_integer([:positive])}")

      File.mkdir_p!(elsewhere)
      File.chmod!(elsewhere, 0o700)
      on_exit(fn -> File.rm_rf!(elsewhere) end)

      {:ok, store} = PaneIntentStore.start_link(root: root)

      assert {:error, %{stage: :validation}} =
               PaneIntentStore.put(store, record(@pane_1, root, %{"project_inbox" => elsewhere}))

      refute File.exists?(Path.join([elsewhere, "state", "pane-attachments.json"]))
    end
  end

  # ============================================================ S1-F1-06

  describe "S1-F1-06 private mode precedes any content" do
    test "the state directory and the temporary file are both private before content",
         %{root: root} do
      fs = new_fs()
      {:ok, store} = PaneIntentStore.start_link(root: root, fs: fs)
      assert :ok = PaneIntentStore.put(store, record(@pane_1, root))

      records = FaultFs.timeline(fs)
      id = pinned_for(root, true)

      assert state_privacy_ok?(records, id)
      assert temp_privacy_ok?(records, id)
    end

    test "a chmod failure on the state directory is reported at stage :permission",
         %{root: root} do
      state = Path.join(root, "state")
      fs = new_fs()
      FaultFs.inject(fs, :chmod, fn [path, _mode] -> path == state end, {:error, :eperm})

      result =
        case PaneIntentStore.start_link(root: root, fs: fs) do
          {:ok, store} -> PaneIntentStore.put(store, record(@pane_1, root))
          {:error, _} = err -> err
        end

      assert {:error, %{stage: :permission, outcome: :unchanged}} = result
      assert FaultFs.fault_fired?(fs, :chmod, fn [p, _] -> p == state end)
    end
  end

  # ============================================================ S1-F1-07

  describe "S1-F1-07 durable success follows the full ordered transaction" do
    test "the committed transaction satisfies the verifier", %{root: root} do
      fs = new_fs()
      {:ok, store} = PaneIntentStore.start_link(root: root, fs: fs)
      assert :ok = PaneIntentStore.put(store, record(@pane_1, root))

      assert durable_write_ok?(FaultFs.timeline(fs), pinned_for(root, true))
    end

    for {op, stage, needs_seed} <- [
          {:lstat, :path, false},
          {:mkdir, :create, false},
          {:chmod, :permission, false},
          {:open_exclusive, :create, false},
          {:read, :read, true},
          {:write, :write, false},
          {:file_sync, :file_sync, false},
          {:close, :close, false},
          {:rename, :rename, false},
          {:directory_sync, :directory_sync, false}
        ] do
      test "a #{op} failure never returns durable success (stage #{stage})", %{root: root} do
        if unquote(needs_seed), do: seed_state!(root, envelope(%{}))

        fs = new_fs()
        FaultFs.inject(fs, unquote(op), 1, {:error, :eio})

        result =
          case PaneIntentStore.start_link(root: root, fs: fs) do
            {:ok, store} -> PaneIntentStore.put(store, record(@pane_1, root))
            {:error, _} = err -> err
          end

        assert {:error, %{stage: unquote(stage)}} = result
        assert FaultFs.fault_fired?(fs, unquote(op), fn _ -> true end)
      end
    end

    test "an unlink failure keeps its provenance in cleanup_errors", %{root: root} do
      fs = new_fs()
      FaultFs.inject(fs, :rename, 1, {:error, :eio})
      FaultFs.inject(fs, :unlink, 1, {:error, :eacces})
      {:ok, store} = PaneIntentStore.start_link(root: root, fs: fs)

      assert {:error, %{stage: :rename, cleanup_errors: [cleanup]}} =
               PaneIntentStore.put(store, record(@pane_1, root))

      assert %{stage: :temporary_cleanup, reason: reason} = cleanup
      assert inspect(reason) =~ "eacces"
      assert inspect(reason) =~ "unlink"
    end

    # G3. Reporting an unresolved close is not reclaiming the descriptor. The
    # reviewer was precise that naming the eventual owner exit is a lifetime
    # fact, not a bound on WHEN it happens - a long-lived owner that keeps
    # serving accumulates one descriptor per occurrence. These rows demand the
    # bound itself: the owner must actually be gone, joined via DOWN rather than
    # assumed. A foreign :file.sync check would NOT prove this - it raises
    # not_on_controlling_process whether the descriptor is open or closed.
    test "an unresolved close terminates the owner, bounding the descriptor", %{root: root} do
      fs = new_fs()
      {:ok, store} = PaneIntentStore.start_link(root: root, fs: fs)
      ref = Process.monitor(store)

      FaultFs.inject(fs, :write, fn _ -> true end, {:error, :enospc})
      FaultFs.inject(fs, :close, fn _ -> true end, {:error, :eio})

      assert {:error, %{stage: :write, cleanup_errors: entries}} =
               PaneIntentStore.put(store, record(@pane_1, root)),
             "the primary data outcome must still be reported, not swallowed by the stop"

      assert Enum.any?(entries, &match?(%{stage: :temporary_cleanup, reason: {:close, :eio}}, &1)),
             "the unresolved close must be reported in the same reply that ends the owner"

      assert_receive {:DOWN, ^ref, :process, ^store, :normal}, 2_000

      refute Process.alive?(store),
             "retention must be bounded by an actual exit, not an eventual one"
    end

    test "a close and an unlink that both fail keep both provenances and still bound", %{root: root} do
      fs = new_fs()
      {:ok, store} = PaneIntentStore.start_link(root: root, fs: fs)
      ref = Process.monitor(store)

      FaultFs.inject(fs, :write, fn _ -> true end, {:error, :enospc})
      FaultFs.inject(fs, :close, fn _ -> true end, {:error, :eio})
      FaultFs.inject(fs, :unlink, fn _ -> true end, {:error, :eacces})

      assert {:error, %{stage: :write, cleanup_errors: entries}} =
               PaneIntentStore.put(store, record(@pane_1, root))

      assert Enum.any?(entries, &match?(%{stage: :temporary_cleanup, reason: {:close, :eio}}, &1))

      assert Enum.any?(
               entries,
               &match?(%{stage: :temporary_cleanup, reason: {:unlink, :eacces}}, &1)
             ),
             "one cleanup failure must not displace the other"

      assert_receive {:DOWN, ^ref, :process, ^store, :normal}, 2_000
    end

    # The row that can actually fail. Without it, "the owner stops" would also be
    # satisfied by a store that dies on every error, which would prove nothing
    # about descriptors. The stop must be specific to an UNRESOLVED CLOSE.
    #
    # The cleanup failure is induced PRE-rename deliberately. An earlier draft
    # used a rename fault, which poisons by contract (outcome :uncertain), so the
    # store then refuses list/1 correctly and the row failed on an expectation
    # the contract never granted - a mis-scoped assertion of mine, not a defect.
    test "a cleanup failure with no unresolved close leaves the owner serving", %{root: root} do
      fs = new_fs()
      {:ok, store} = PaneIntentStore.start_link(root: root, fs: fs)
      ref = Process.monitor(store)

      FaultFs.inject(fs, :write, fn _ -> true end, {:error, :enospc})
      FaultFs.inject(fs, :unlink, fn _ -> true end, {:error, :eacces})

      assert {:error, %{stage: :write, cleanup_errors: [%{stage: :temporary_cleanup}]}} =
               PaneIntentStore.put(store, record(@pane_1, root))

      refute_receive {:DOWN, ^ref, :process, ^store, _}, 200
      assert Process.alive?(store), "an ordinary cleanup failure must not end the owner"
      assert {:ok, _} = PaneIntentStore.list(store), "and a pre-rename failure must still serve"
    end

    # H2. The debt-deriving lstat previously went through match?/2, which mapped
    # EVERY non-directory result - including {:error, :eio} - to false. An
    # uncertain observation silently became "no durability debt", and the next
    # call was acknowledged without the restart root sync.
    #
    # An error is not an answer. The corrected startup refuses cleanly through the
    # closed :path stage instead of guessing. A mutant that restores the match?/2
    # collapse must fail THIS row.
    test "an uncertain state-directory inspection refuses startup rather than owing nothing",
         %{root: root} do
      {:ok, seed} = PaneIntentStore.start_link(root: root)
      :ok = PaneIntentStore.put(seed, record(@pane_1, root))
      stop_and_join!(seed)

      fs = new_fs()
      state_dir = Path.join(root, "state")
      final = state_path(root)

      # Targeted by phase, not ordinal: `inspect_root` checks every ancestor,
      # so adding path segments shifts the later lstat calls.
      #
      # Path alone cannot replace it, because `inspect_state` reads the SAME state
      # path earlier in startup. The discriminator is the successful snapshot read
      # that sits between the two, so the fault arms only once that read is
      # reached - and the timeline below proves the ordering rather than assuming
      # it.
      #
      # Both matchers are evaluated inside the double's own Agent process, so they
      # share that process dictionary. Neither may call back into FaultFs: that
      # would block on the Agent it is already executing in.
      FaultFs.inject(
        fs,
        :read,
        fn args ->
          if args == [final], do: Process.put(:snapshot_read_reached, true)
          # An observer, never a fault. Returning false leaves the read untouched,
          # so the fault term below is unreachable by construction.
          false
        end,
        {:error, :never_armed}
      )

      FaultFs.inject(
        fs,
        :lstat,
        fn args -> args == [state_dir] and Process.get(:snapshot_read_reached, false) end,
        {:error, :eio}
      )

      assert {:error, %{stage: :path, outcome: :unchanged, reason: {path, :eio}}} =
               PaneIntentStore.start_link(root: root, fs: fs),
             "an lstat error must not be collapsed into 'no durability debt'"

      assert path == state_dir, "the refused lstat must be the state directory"

      # The phase witness, RETAINED rather than assumed. The snapshot read must
      # have been invoked, returned successfully, and completed before the lstat
      # that was refused.
      timeline = FaultFs.timeline(fs)

      assert %{disposition: :invoked, value: {:ok, _}, result_at: read_at} =
               Enum.find(timeline, &(&1.op == :read and &1.args == [final])),
             "the final snapshot read must have SUCCEEDED before the debt derivation"

      assert %{attempt_at: debt_at} =
               Enum.find(
                 timeline,
                 &(&1.op == :lstat and &1.args == [state_dir] and &1.disposition == :refused)
               ),
             "the refused call must be an lstat of the state directory"

      assert read_at < debt_at,
             "phase: the successful snapshot read must precede the targeted state lstat"

      # Consumption witness: one fault fired, on the intended call, with the exact
      # error. An attempt is not proof a matcher fired.
      assert [{:lstat, [^state_dir], {:error, :eio}}] = FaultFs.faults_fired(fs),
             "exactly one fault must fire and it must be the state-directory lstat"

      # And the decoy is proven distinct rather than argued away: `inspect_state`
      # observed the same path earlier and was NOT refused.
      assert Enum.count(timeline, &(&1.op == :lstat and &1.args == [state_dir])) == 2,
             "both state-path lstats must be observed, the earlier one unrefused"
    end

    # The same scenario under a materially deeper root. Ordinal targeting could
    # not survive this by construction - every extra ancestor segment shifts every
    # later ordinal - so this row is the regression guard that keeps the phase
    # arming above depth-independent. Cleanup is joined: `deep` lives under the
    # setup root, which is removed by the existing on_exit.
    test "the phase-armed debt fault survives a materially deeper root", %{root: root} do
      deep = Path.join([root, "a", "b", "c", "d", "e", "f"])
      File.mkdir_p!(deep)
      File.chmod!(deep, 0o700)

      assert length(Path.split(deep)) - length(Path.split(root)) == 6,
             "the fixture must actually be deeper, or this row proves nothing"

      {:ok, seed} = PaneIntentStore.start_link(root: deep)
      :ok = PaneIntentStore.put(seed, record(@pane_1, deep))
      stop_and_join!(seed)

      fs = new_fs()
      state_dir = Path.join(deep, "state")
      final = state_path(deep)

      FaultFs.inject(
        fs,
        :read,
        fn args ->
          if args == [final], do: Process.put(:snapshot_read_reached, true)
          false
        end,
        {:error, :never_armed}
      )

      FaultFs.inject(
        fs,
        :lstat,
        fn args -> args == [state_dir] and Process.get(:snapshot_read_reached, false) end,
        {:error, :eio}
      )

      assert {:error, %{stage: :path, outcome: :unchanged, reason: {^state_dir, :eio}}} =
               PaneIntentStore.start_link(root: deep, fs: fs),
             "depth must not change which call the fault lands on"

      assert [{:lstat, [^state_dir], {:error, :eio}}] = FaultFs.faults_fired(fs)
    end

    # H1. mkdir can succeed and the chmod after it still fail, which leaves the
    # state directory PRESENT. The obligation has to survive that error on the
    # SAME owner - no restart, no host repair - or the retry finds a private
    # existing directory, discharges nothing, and acknowledges a write whose root
    # entry was never synced.
    #
    # The chmod must have its real EFFECT and then fail. A plain injected error
    # skips the effect, leaving the directory at its mkdir mode, and the store
    # then correctly refuses the retry with :unsafe_mode - correct behaviour, but
    # a different scenario. An earlier revision of this row asserted the retry
    # succeeded there, which quietly assumed the store would repair the mode for
    # us. It does not, and it should not: silently chmod-ing an already-exposed
    # directory would not undo the exposure.
    test "a chmod failure after directory creation still owes the root sync on retry",
         %{root: root} do
      state_dir = Path.join(root, "state")

      fs =
        {AiPair.Test.PaneIntentChmodEffectThenError, %{target: state_dir, observer: self()}}

      {:ok, store} = PaneIntentStore.start_link(root: root, fs: fs)

      assert {:error, %{stage: :permission}} = PaneIntentStore.delete(store, "%99")

      assert_receive {:chmod_effect_then_error, ^state_dir, :ok},
                     2_000,
                     "precondition: the chmod must have actually SUCCEEDED before reporting failure"

      refute_received {:directory_sync, ^root, _},
                      "precondition: the failed attempt must not already have synced the root"

      # Same owner. No restart, no host repair.
      assert :ok = PaneIntentStore.delete(store, "%99")

      assert_receive {:directory_sync, ^root, :ok},
                     2_000,
                     "the obligation must survive the failed call and be discharged on the retry"
    end

    # H6. Delete's POST-RENAME state-directory sync, executed rather than inferred.
    # The G5 callback matrix reaches root directory_sync first on a restarted
    # owner and checks the STAGE only; it never exercises this outcome. Sharing a
    # commit helper with put is not evidence that this path behaves correctly.
    test "a delete whose post-rename state sync fails is uncertain, poisons, and the effect is real",
         %{root: root} do
      {:ok, seed} = PaneIntentStore.start_link(root: root)
      :ok = PaneIntentStore.put(seed, record(@pane_1, root))
      :ok = PaneIntentStore.put(seed, record(@pane_2, root))
      stop_and_join!(seed)

      state_dir = Path.join(root, "state")
      fs = new_fs()
      {:ok, store} = PaneIntentStore.start_link(root: root, fs: fs)

      # Targeted at the STATE directory specifically, so this cannot be satisfied
      # by the root sync that a restarted owner performs first.
      state_sync = fn [dir] -> dir == state_dir end
      FaultFs.inject(fs, :directory_sync, state_sync, {:error, :eio})

      assert {:error,
              %{
                stage: :directory_sync,
                reason: {:directory_sync, :eio},
                outcome: :uncertain
              }} = PaneIntentStore.delete(store, @pane_1)

      assert FaultFs.fault_fired?(fs, :directory_sync, state_sync),
             "the injection must have been CONSUMED, not merely planned"

      assert {:error, %{stage: :poisoned}} = PaneIntentStore.list(store),
             "an uncertain commit must poison every subsequent call"

      stop_and_join!(store)

      # The rename itself succeeded, so the delete really happened. A fresh owner
      # must observe it - uncertainty is about durability, not about inventing a
      # rollback that never occurred.
      {:ok, reloaded} = PaneIntentStore.start_link(root: root)
      assert {:ok, [only]} = PaneIntentStore.list(reloaded)
      assert only["pane_id"] == @pane_2

      files = Path.wildcard(Path.join(state_dir, "*"))
      assert length(files) == 1, "a completed rename leaves exactly the committed envelope"

      {:ok, envelope} = Jason.decode(File.read!(hd(files)))

      refute Map.has_key?(envelope["attachments"], @pane_1),
             "and the committed BYTES must not still carry the deleted pane"
    end

    # One semantic callback, several internal operations. directory_sync opens,
    # syncs and closes, and each of those must be checked rather than discarded.
    # The open substep is inducible against a real filesystem and is asserted
    # here by its tag. The sync and close substeps are NOT inducible that way -
    # a directory opened read-only syncs successfully - so they are driven
    # through the compiled arity-3 seam instead. An earlier revision of this
    # comment recorded them as an uncovered gap; that is no longer true and the
    # sentence is corrected rather than left standing.
    test "the backend checks and tags directory_sync's own open substep", %{root: root} do
      assert AiPair.PaneIntentStore.Fs.SystemFs.directory_sync(nil, root) == :ok

      missing = Path.join(root, "no-such-directory")

      assert {:error, {:open, _reason}} =
               AiPair.PaneIntentStore.Fs.SystemFs.directory_sync(nil, missing),
             "a failed open must be reported with its substep, not as a bare posix reason"

      regular = Path.join(root, "a-regular-file")
      File.write!(regular, "x")

      assert {:error, {:open, _reason}} =
               AiPair.PaneIntentStore.Fs.SystemFs.directory_sync(nil, regular)
    end

    # Named for what it actually does. An earlier revision called this "the real
    # default path", which it is not - it drives the SCRIPTED io. The real
    # default path is exercised by the arity-2 rows above, against a real
    # filesystem. Correcting the name rather than leaving it is the point: a test
    # whose name overstates its subject is a false attribution claim.
    test "the seam records open, sync and close in order on one descriptor", %{root: root} do
      AiPair.Test.PaneIntentScriptedIo.script()

      assert AiPair.PaneIntentStore.Fs.SystemFs.directory_sync(
               nil,
               root,
               AiPair.Test.PaneIntentScriptedIo
             ) == :ok

      assert [{:open, opened, options}, {:sync, fd}, {:close, fd}] =
               AiPair.Test.PaneIntentScriptedIo.calls()

      assert opened == root, "directory_sync must sync exactly the directory it is given"
      assert options == [:read, :raw, :binary, :directory]
      assert fd == {:scripted_fd, root}, "the SAME descriptor must be synced and then closed"
    end

    test "a failing sync is reported and the close is still attempted", %{root: root} do
      AiPair.Test.PaneIntentScriptedIo.script(sync: {:error, :eio})

      assert {:error, {:sync, :eio}} =
               AiPair.PaneIntentStore.Fs.SystemFs.directory_sync(
                 nil,
                 root,
                 AiPair.Test.PaneIntentScriptedIo
               )

      assert [{:open, _, _}, {:sync, fd}, {:close, fd}] =
               AiPair.Test.PaneIntentScriptedIo.calls(),
             "close must be ATTEMPTED after a failing sync, not skipped - this ordering is the property"
    end

    test "a failing close alone is reported with its own substep", %{root: root} do
      AiPair.Test.PaneIntentScriptedIo.script(close: {:error, :ebadf})

      assert {:error, {:close, :ebadf}} =
               AiPair.PaneIntentStore.Fs.SystemFs.directory_sync(
                 nil,
                 root,
                 AiPair.Test.PaneIntentScriptedIo
               )
    end

    # This row FAILS under the previous shape, which discarded the close reason
    # entirely - that is precisely why the combined tag exists, and the retained
    # g6-ignore-close-reason mutant kills this single row and no other. An
    # earlier revision of this comment said the row "would have PASSED" under the
    # old shape, which is backwards and contradicted my own mutation evidence.
    test "when sync and close both fail the close reason is carried, not discarded", %{root: root} do
      AiPair.Test.PaneIntentScriptedIo.script(sync: {:error, :eio}, close: {:error, :ebadf})

      assert {:error, {:sync, :eio, {:close, :ebadf}}} =
               AiPair.PaneIntentStore.Fs.SystemFs.directory_sync(
                 nil,
                 root,
                 AiPair.Test.PaneIntentScriptedIo
               ),
             "the sync failure stays primary AND the close failure survives alongside it"

      assert [{:open, _, _}, {:sync, _}, {:close, _}] =
               AiPair.Test.PaneIntentScriptedIo.calls()
    end

    # H3. A REAL owned directory descriptor, on the product path.
    #
    # The row this replaces injected a precomputed {:close, _} through the fault
    # double, which returns before any backend open - so no descriptor ever
    # existed and nothing about reclamation was observed. It also asserted
    # `outcome in [:unchanged, :uncertain]`, which are the only two outcomes the
    # contract defines: a tautology that cannot fail. Both defects were mine.
    #
    # Here the backend really opens and syncs the state directory, deliberately
    # does not close it, and reports the failure. The descriptor is genuinely
    # open and owned by the owner process, so the four required observations are
    # each measured rather than assumed: positive live-FD while the owner is
    # alive; the fd term retained by a SURVIVING observer (this test); the exact
    # normal owner DOWN; and actual reclamation afterwards.
    test "a real leaked directory descriptor is observed live and reclaimed on owner DOWN",
         %{root: root} do
      # A SURVIVING observer that holds the raw term in explicit state. An earlier
      # revision wrote `_retained = fd`, an unused binding that is read by nothing
      # and therefore establishes nothing about the term being live across the
      # census. Teardown is registered BEFORE any assertion so the helper is
      # joined even when a row fails.
      {:ok, keeper} = Agent.start_link(fn -> nil end)
      on_exit(fn -> join_owned!(keeper) end)

      fs = {AiPair.Test.PaneIntentLeakyDirSync, %{target: "/state", observer: self()}}
      {:ok, store} = PaneIntentStore.start_link(root: root, fs: fs)
      ref = Process.monitor(store)

      caller = Task.async(fn -> PaneIntentStore.put(store, record(@pane_1, root)) end)

      assert_receive {:leaked_fd, dir, fd, owner}, 5_000
      assert owner == store, "the descriptor must be owned by the STORE, not by the test"
      Agent.update(keeper, fn _ -> fd end)

      # The owner is LINGERING here: it holds a real open descriptor and has not
      # concluded. The same census must see it, otherwise an oracle that returned
      # zero in both conditions would "prove" reclamation by never seeing anything.
      assert {:ok, live} = dir_fd_census(dir),
             "the census itself must succeed; an unavailable census is not evidence"

      assert live > 0,
             "positive live-FD under the lingering condition: the descriptor is open"

      send(owner, :continue)

      assert {:error,
              %{
                stage: :directory_sync,
                reason: {:directory_sync, {:close, :ebadf}},
                outcome: :uncertain
              }} = Task.await(caller, 5_000),
             "the exact stage, reason and post-rename uncertainty must all survive the stop"

      assert_receive {:DOWN, ^ref, :process, ^store, :normal}, 5_000

      assert {:ok, 0} = dir_fd_census(dir),
             "actual reclamation: the descriptor must be gone once the owner has exited"

      # Read the retained term back AFTER the reclamation observation, from a
      # process that did not die. Holding a reference elsewhere does not keep the
      # descriptor alive - ownership does - and this is what makes that claim
      # observable rather than asserted.
      assert Agent.get(keeper, & &1) == fd,
             "the raw term is still held by a surviving observer across the census"
    end

    # The ADVERSE half, deliberately independent of DOWN.
    #
    # The row above proves positive-before and absent-after-joined-DOWN. It cannot
    # also serve as the oracle's discrimination, because under a lingering owner it
    # fails at the DOWN assertion BEFORE reaching any census - which is exactly how
    # I previously mis-attributed the linger mutant's failure as "the oracle sees a
    # still-open descriptor". It saw nothing; it timed out waiting for DOWN.
    #
    # So this row asserts only that the same valid census SEES the owned descriptor
    # while the owner holds it and has not concluded. No DOWN assertion appears
    # here. An oracle that returned zero in both the healthy and lingering
    # conditions would pass the row above and fail this one.
    test "the same census sees the owned descriptor STILL OPEN while the owner lingers",
         %{root: root} do
      fs = {AiPair.Test.PaneIntentLeakyDirSync, %{target: "/state", observer: self()}}
      {:ok, store} = PaneIntentStore.start_link(root: root, fs: fs)
      caller = Task.async(fn -> PaneIntentStore.put(store, record(@pane_1, root)) end)

      assert_receive {:leaked_fd, dir, _fd, owner}, 5_000
      assert Process.alive?(owner), "precondition: the owner is lingering, not concluded"

      assert {:ok, still_open} = dir_fd_census(dir),
             "the census must succeed; an unavailable census is not an observation"

      assert still_open > 0,
             "the oracle must SEE the owned descriptor while the owner holds it open"

      send(owner, :continue)
      assert {:error, %{stage: :directory_sync}} = Task.await(caller, 5_000)
    end

    # Combined sync AND close failure, composed by the product's own backend body
    # rather than hand-built here. This is the shape the previous fixture could not
    # produce, because it constructed its own error tuple instead of calling
    # SystemFs.directory_sync/3.
    test "a combined directory sync and close failure carries both reasons and bounds the owner",
         %{root: root} do
      fs =
        {AiPair.Test.PaneIntentLeakyDirSync,
         %{
           target: "/state",
           observer: self(),
           io: [sync: {:error, :eio}, close: {:error, :ebadf}]
         }}

      {:ok, store} = PaneIntentStore.start_link(root: root, fs: fs)
      ref = Process.monitor(store)
      caller = Task.async(fn -> PaneIntentStore.put(store, record(@pane_1, root)) end)

      assert_receive {:leaked_fd, dir, _fd, owner}, 5_000
      assert {:ok, live} = dir_fd_census(dir)
      assert live > 0, "the descriptor is open even though the sync also failed"

      send(owner, :continue)

      assert {:error,
              %{
                stage: :directory_sync,
                reason: {:directory_sync, {:sync, :eio, {:close, :ebadf}}},
                outcome: :uncertain
              }} = Task.await(caller, 5_000),
             "the sync reason stays primary AND the close reason survives, through the product"

      assert_receive {:DOWN, ^ref, :process, ^store, :normal}, 5_000

      assert {:ok, 0} = dir_fd_census(dir),
             "an unresolved close inside a COMBINED failure must bound the owner too"
    end

    # The pre-rename half of the matrix. The root sync is owed by state-directory
    # creation and runs BEFORE any rename, so its outcome is :unchanged - not the
    # :uncertain of the post-rename state sync above. Asserting the outcome here is
    # what distinguishes the two sites rather than treating them as one.
    test "a root pre-rename directory close failure is unchanged and still bounds the owner",
         %{root: root} do
      fs = {AiPair.Test.PaneIntentLeakyDirSync, %{target: root, observer: self()}}
      {:ok, store} = PaneIntentStore.start_link(root: root, fs: fs)
      ref = Process.monitor(store)
      caller = Task.async(fn -> PaneIntentStore.put(store, record(@pane_1, root)) end)

      assert_receive {:leaked_fd, dir, _fd, owner}, 5_000
      assert dir == root, "this row must exercise the ROOT sync, not the state directory"

      assert {:ok, live} = dir_fd_census(dir)
      assert live > 0

      send(owner, :continue)

      assert {:error,
              %{
                stage: :directory_sync,
                reason: {:directory_sync, {:close, :ebadf}},
                outcome: :unchanged
              }} = Task.await(caller, 5_000),
             "a pre-rename failure leaves the prior committed view intact"

      assert_receive {:DOWN, ^ref, :process, ^store, :normal}, 5_000
      assert {:ok, 0} = dir_fd_census(dir)
    end

    # The fourth matrix cell: COMBINED sync+close at the ROOT, pre-rename. The
    # state-directory combined case is :uncertain because it follows the rename;
    # this one precedes it and must stay :unchanged. Both reasons are composed by
    # the product's own backend body.
    test "a root pre-rename COMBINED sync and close failure is unchanged and bounds the owner",
         %{root: root} do
      fs =
        {AiPair.Test.PaneIntentLeakyDirSync,
         %{
           target: root,
           observer: self(),
           io: [sync: {:error, :eio}, close: {:error, :ebadf}]
         }}

      {:ok, store} = PaneIntentStore.start_link(root: root, fs: fs)
      ref = Process.monitor(store)
      caller = Task.async(fn -> PaneIntentStore.put(store, record(@pane_1, root)) end)

      assert_receive {:leaked_fd, dir, _fd, owner}, 5_000
      assert dir == root, "this row must exercise the ROOT sync, not the state directory"

      assert {:ok, live} = dir_fd_census(dir)
      assert live > 0, "the descriptor is open even though the sync also failed"

      send(owner, :continue)

      assert {:error,
              %{
                stage: :directory_sync,
                reason: {:directory_sync, {:sync, :eio, {:close, :ebadf}}},
                outcome: :unchanged
              }} = Task.await(caller, 5_000),
             "both reasons survive, and a pre-rename failure leaves the prior view intact"

      assert_receive {:DOWN, ^ref, :process, ^store, :normal}, 5_000
      assert {:ok, 0} = dir_fd_census(dir)
    end

    # The TEMP half of the matrix. The existing temp-close controls observe
    # cleanup entries and DOWN; none of them observes the descriptor. This one
    # does, against a genuinely open temporary file.
    test "an unresolved temp close leaves a REAL descriptor, observed live then reclaimed",
         %{root: root} do
      {:ok, keeper} = Agent.start_link(fn -> nil end)
      on_exit(fn -> join_owned!(keeper) end)

      fs = {AiPair.Test.PaneIntentLeakyTempClose, %{observer: self(), fail_write: true}}
      {:ok, store} = PaneIntentStore.start_link(root: root, fs: fs)
      ref = Process.monitor(store)
      caller = Task.async(fn -> PaneIntentStore.put(store, record(@pane_1, root)) end)

      assert_receive {:leaked_temp_fd, path, fd, owner}, 5_000
      assert owner == store, "the temp descriptor must be owned by the STORE"
      Agent.update(keeper, fn _ -> fd end)

      assert {:ok, live} = dir_fd_census(path),
             "the census must succeed; an unavailable census is not an observation"

      assert live > 0, "the TEMP descriptor is genuinely open while the owner holds it"

      send(owner, :continue)

      assert {:error,
              %{
                stage: :write,
                reason: {:write, :enospc},
                outcome: :unchanged,
                cleanup_errors: entries
              }} = Task.await(caller, 5_000),
             "the ORIGINAL primary reason must survive alongside the cleanup errors, " <>
               "not just its stage and outcome"

      assert Enum.any?(
               entries,
               &match?(%{stage: :temporary_cleanup, reason: {:close, :ebadf}}, &1)
             ),
             "and the unresolved cleanup close is reported alongside it"

      assert_receive {:DOWN, ^ref, :process, ^store, :normal}, 5_000

      assert {:ok, 0} = dir_fd_census(path),
             "the temp descriptor must be reclaimed once the owner has exited"

      assert Agent.get(keeper, & &1) == fd,
             "the raw term is still held by a surviving observer across the census"
    end

    # The explicit linked non-trapping caller witness. A Task.async caller is NOT
    # this: start_link links the store to the TEST process, not to the Task, so
    # citing it would be claiming a link that does not exist. Here the caller
    # links itself to the store and does not trap exits.
    test "a linked non-trapping caller gets the typed error and survives the owner's normal stop",
         %{root: root} do
      fs = {AiPair.Test.PaneIntentLeakyDirSync, %{target: "/state", observer: self()}}
      {:ok, store} = PaneIntentStore.start_link(root: root, fs: fs)
      test_pid = self()

      caller =
        spawn(fn ->
          Process.link(store)
          false = Process.flag(:trap_exit, false)
          result = PaneIntentStore.put(store, record(@pane_1, root))
          send(test_pid, {:caller_result, self(), result})

          receive do
            :stop -> :ok
          after
            10_000 -> :ok
          end
        end)

      caller_ref = Process.monitor(caller)

      # D. Registered IMMEDIATELY after spawn, before any assertion. The reviewer
      # demonstrated the leak by forcing a failure after the typed reply: the
      # trailing send(:stop) never ran, and their after_suite observed
      # caller_alive_after_failed_test: true and had to reclaim my fixture. A
      # teardown that only runs on the success path is not teardown.
      on_exit(fn -> reclaim_caller!(caller) end)

      assert_receive {:leaked_fd, _dir, _fd, owner}, 5_000
      send(owner, :continue)

      assert_receive {:caller_result, ^caller, {:error, %{stage: :directory_sync}}},
                     5_000,
                     "the linked caller must receive the typed error, not an exit"

      refute_receive {:DOWN, ^caller_ref, :process, ^caller, _}, 300

      assert Process.alive?(caller),
             "a :normal owner stop must not take a linked non-trapping caller with it"
    end

    # Supervision EXECUTED, not inspected. Asserting the child_spec's shape says
    # what the policy is; it does not show what the policy does. This runs the
    # store under a real supervisor, induces the normal product stop, and
    # observes both required consequences: a DIFFERENT replacement owner, and no
    # automatic replay of the failed transaction.
    #
    # No-replay is observed as the absence of a second barrier. The rename itself
    # had already succeeded, so the committed record is still there - the restart
    # neither replays the failed call nor rolls back what it committed.
    test "under a supervisor a normal stop yields a DIFFERENT owner, with no replay",
         %{root: root} do
      fs = {AiPair.Test.PaneIntentLeakyDirSync, %{target: "/state", observer: self()}}

      spec = %{
        id: :pane_intent_store_supervised,
        start: {PaneIntentStore, :start_link, [[root: root, fs: fs]]},
        restart: :permanent
      }

      {:ok, sup} = Supervisor.start_link([spec], strategy: :one_for_one)
      on_exit(fn -> join_owned!(sup) end)

      assert [{_id, first, _type, _mods}] = Supervisor.which_children(sup)
      assert is_pid(first)
      ref = Process.monitor(first)

      caller = Task.async(fn -> PaneIntentStore.put(first, record(@pane_1, root)) end)
      assert_receive {:leaked_fd, _dir, _fd, owner}, 5_000
      send(owner, :continue)

      assert {:error, %{stage: :directory_sync}} = Task.await(caller, 5_000)
      assert_receive {:DOWN, ^ref, :process, ^first, :normal}, 5_000

      second =
        Enum.reduce_while(1..100, nil, fn _attempt, _acc ->
          case Supervisor.which_children(sup) do
            [{_id, pid, _type, _mods}] when is_pid(pid) and pid != first ->
              {:halt, pid}

            _not_yet ->
              Process.sleep(20)
              {:cont, nil}
          end
        end)

      assert is_pid(second), "a permanent child_spec must start a replacement owner"

      assert second != first,
             "the service returns as a DIFFERENT process; it is not the same owner resumed"

      refute_receive {:leaked_fd, _dir2, _fd2, _owner2},
                     500,
                     "the restart must not replay the failed transaction"

      assert {:ok, [only]} = PaneIntentStore.list(second)

      assert only["pane_id"] == @pane_1,
             "the rename had already committed, so the replacement owner reloads it"
    end

    # Selected existing behaviour, recorded rather than claimed. A default
    # permanent child_spec CAN restart a different owner, so nothing here asserts
    # that the global service stays stopped after a normal termination.
    test "the selected supervision behaviour is the default permanent child_spec", %{root: root} do
      spec = PaneIntentStore.child_spec(root: root)

      assert %{id: AiPair.PaneIntentStore, start: {AiPair.PaneIntentStore, :start_link, [opts]}} =
               spec

      assert Keyword.get(opts, :root) == root

      assert Map.get(spec, :restart, :permanent) == :permanent,
             "the selected behaviour is permanent; a restart yields a DIFFERENT owner process"
    end
  end

  # ============================================================ S1-F1-08

  describe "S1-F1-08 pre-rename preserves, post-rename poisons" do
    test "a pre-rename failure leaves the previously committed bytes intact", %{root: root} do
      {:ok, store} = PaneIntentStore.start_link(root: root)
      :ok = PaneIntentStore.put(store, record(@pane_1, root))
      committed = File.read!(state_path(root))
      stop_and_join!(store)

      fs = new_fs()
      FaultFs.inject(fs, :write, 1, {:error, :enospc})
      {:ok, store2} = PaneIntentStore.start_link(root: root, fs: fs)

      assert {:error, %{stage: :write, outcome: :unchanged}} =
               PaneIntentStore.put(store2, record(@pane_2, root))

      assert File.read!(state_path(root)) == committed
    end

    test "a directory_sync failure after rename poisons every later call", %{root: root} do
      state = Path.join(root, "state")
      fs = new_fs()
      FaultFs.inject(fs, :directory_sync, fn [dir] -> dir == state end, {:error, :eio})
      {:ok, store} = PaneIntentStore.start_link(root: root, fs: fs)

      assert {:error, %{outcome: :uncertain}} = PaneIntentStore.put(store, record(@pane_1, root))
      assert {:error, %{stage: :poisoned, outcome: :uncertain}} = PaneIntentStore.list(store)
      assert {:error, %{stage: :poisoned}} = PaneIntentStore.put(store, record(@pane_2, root))
      assert {:error, %{stage: :poisoned}} = PaneIntentStore.delete(store, @pane_1)
    end

    # Effect-then-error. The hook runs BEFORE the backend, so it performs the real
    # rename itself; the seam's own rename then fails with :enoent because the
    # temporary is already gone. The replacement genuinely committed while the API
    # reported failure. This is the converse of the row above: :uncertain must not
    # be read as proof of non-commit, and the reload proves the effect landed.
    test "a rename that took effect but reported an error is uncertain, not proof of non-commit",
         %{root: root} do
      {:ok, seed} = PaneIntentStore.start_link(root: root)
      :ok = PaneIntentStore.put(seed, record(@pane_1, root))
      stop_and_join!(seed)

      state = Path.join(root, "state")
      fs = new_fs()

      FaultFs.inject(
        fs,
        :rename,
        1,
        {:hook,
         fn ->
           state
           |> File.ls!()
           |> Enum.find(&String.starts_with?(&1, "pane-attachments.json.tmp-"))
           |> case do
             nil -> :ok
             tmp -> File.rename!(Path.join(state, tmp), state_path(root))
           end
         end}
      )

      {:ok, store} = PaneIntentStore.start_link(root: root, fs: fs)

      assert {:error, %{stage: :rename, outcome: :uncertain}} =
               PaneIntentStore.put(store, record(@pane_2, root))

      assert {:error, %{stage: :poisoned}} = PaneIntentStore.list(store)

      stop_and_join!(store)
      {:ok, reloaded} = PaneIntentStore.start_link(root: root)

      assert {:ok, records} = PaneIntentStore.list(reloaded)

      assert Enum.map(records, & &1["pane_id"]) == [@pane_1, @pane_2],
             "the renamed snapshot really is committed; an uncertain result must not " <>
               "be reported as though the write had not happened"
    end
  end

  # ============================================================ S1-F1-09

  describe "S1-F1-09 delete failure is visible" do
    test "a delete whose rename fails is uncertain and poisons the owner", %{root: root} do
      {:ok, store} = PaneIntentStore.start_link(root: root)
      :ok = PaneIntentStore.put(store, record(@pane_1, root))
      committed = File.read!(state_path(root))
      stop_and_join!(store)

      fs = new_fs()
      FaultFs.inject(fs, :rename, 1, {:error, :eio})
      {:ok, store2} = PaneIntentStore.start_link(root: root, fs: fs)

      assert {:error, %{stage: :rename, outcome: :uncertain}} =
               PaneIntentStore.delete(store2, @pane_1)

      assert {:error, %{stage: :poisoned}} = PaneIntentStore.list(store2)

      # Separate observation about this pre-effect injection, not the API's result.
      assert File.read!(state_path(root)) == committed
    end

    test "a corrupt store refuses at startup and never starts a half-ready owner",
         %{root: root} do
      seed_state!(root, "{not json")
      assert {:error, %{stage: :decode}} = PaneIntentStore.start_link(root: root)
    end

    test "deleting an absent pane is idempotent after a healthy load", %{root: root} do
      {:ok, store} = PaneIntentStore.start_link(root: root)
      assert :ok = PaneIntentStore.put(store, record(@pane_1, root))

      assert :ok = PaneIntentStore.delete(store, @pane_2)
      assert {:ok, [still]} = PaneIntentStore.list(store)
      assert still["pane_id"] == @pane_1
    end

    # G5. The frozen row requires the SAME fault matrix for delete, and S1-F1-07
    # injects through put and startup rather than delete. The callback set below
    # was MEASURED from a recorded trace, not inferred from the implementation:
    # a delete on a seeded root reaches lstat, directory_sync, open_exclusive,
    # chmod, write, file_sync, close and rename. `read` is startup-only and is
    # excluded honestly, with its own control; `mkdir` is unreachable while the
    # state directory exists and is covered by a fresh-root delete below.
    #
    # Faults are injected AFTER startup and matched on arguments rather than by
    # call ordinal, because startup already consumes the ordinal for every
    # callback it shares with the delete path.
    for {op, stage} <- [
          {:lstat, :path},
          {:directory_sync, :directory_sync},
          {:open_exclusive, :create},
          {:chmod, :permission},
          {:write, :write},
          {:file_sync, :file_sync},
          {:close, :close},
          {:rename, :rename}
        ] do
      test "a delete whose #{op} fails is visible at stage #{stage}", %{root: root} do
        {:ok, seed} = PaneIntentStore.start_link(root: root)
        :ok = PaneIntentStore.put(seed, record(@pane_1, root))
        stop_and_join!(seed)

        fs = new_fs()
        {:ok, store} = PaneIntentStore.start_link(root: root, fs: fs)
        FaultFs.inject(fs, unquote(op), fn _ -> true end, {:error, :eio})

        assert {:error, %{stage: unquote(stage)}} = PaneIntentStore.delete(store, @pane_1)

        assert FaultFs.fault_fired?(fs, unquote(op), fn _ -> true end),
               "the injected delete fault must actually have been consumed"
      end
    end

    test "a delete on a store with no state directory reaches mkdir", %{root: root} do
      refute File.exists?(Path.join(root, "state"))

      fs = new_fs()
      {:ok, store} = PaneIntentStore.start_link(root: root, fs: fs)
      FaultFs.inject(fs, :mkdir, fn _ -> true end, {:error, :eio})

      assert {:error, %{stage: :create}} = PaneIntentStore.delete(store, @pane_1)
      assert FaultFs.fault_fired?(fs, :mkdir, fn _ -> true end)
    end

    test "a delete whose cleanup unlink also fails keeps both provenances", %{root: root} do
      {:ok, seed} = PaneIntentStore.start_link(root: root)
      :ok = PaneIntentStore.put(seed, record(@pane_1, root))
      stop_and_join!(seed)

      fs = new_fs()
      {:ok, store} = PaneIntentStore.start_link(root: root, fs: fs)
      FaultFs.inject(fs, :write, fn _ -> true end, {:error, :enospc})
      FaultFs.inject(fs, :unlink, fn _ -> true end, {:error, :eacces})

      assert {:error, %{stage: :write, cleanup_errors: entries}} =
               PaneIntentStore.delete(store, @pane_1)

      assert Enum.any?(
               entries,
               &match?(%{stage: :temporary_cleanup, reason: {:unlink, :eacces}}, &1)
             ),
             "the primary delete failure and its cleanup failure must both survive"
    end

    # The honest half of the matrix: recording which callback a delete does NOT
    # reach, so the exclusion is a measurement rather than an assumption.
    test "read is startup-only and a delete never invokes it", %{root: root} do
      {:ok, seed} = PaneIntentStore.start_link(root: root)
      :ok = PaneIntentStore.put(seed, record(@pane_1, root))
      stop_and_join!(seed)

      fs = new_fs()
      {:ok, store} = PaneIntentStore.start_link(root: root, fs: fs)

      reads_after_startup = FaultFs.count(fs, :read)
      assert reads_after_startup > 0, "precondition: startup does read the committed snapshot"

      assert :ok = PaneIntentStore.delete(store, @pane_1)

      assert FaultFs.count(fs, :read) == reads_after_startup,
             "a delete must not invoke read; claiming that route exists would be false"
    end
  end

  # ============================================================ S1-F1-10

  describe "S1-F1-10 restart reloads a complete snapshot" do
    test "a stopped and joined owner reloads exactly the committed snapshot", %{root: root} do
      {:ok, store} = PaneIntentStore.start_link(root: root)
      :ok = PaneIntentStore.put(store, record(@pane_1, root))
      committed = File.read!(state_path(root))
      stop_and_join!(store)

      {:ok, reloaded} = PaneIntentStore.start_link(root: root)
      assert {:ok, [one]} = PaneIntentStore.list(reloaded)
      assert one["pane_id"] == @pane_1
      assert File.read!(state_path(root)) == committed
    end

    test "an abandoned temporary file is retained and never read as committed", %{root: root} do
      state = Path.join(root, "state")
      File.mkdir_p!(state)
      File.chmod!(state, 0o700)
      abandoned = Path.join(state, "pane-attachments.json.tmp-abandoned")
      File.write!(abandoned, "{}")
      File.chmod!(abandoned, 0o600)

      {:ok, store} = PaneIntentStore.start_link(root: root)

      assert {:ok, []} = PaneIntentStore.list(store)
      assert File.exists?(abandoned)
    end

    # Owner crash at each persistence boundary. The hook runs INSIDE the owner, so
    # killing self() crashes it exactly at that seam call - deterministic, with no
    # sleep and no external timing. Whatever the boundary, the reload must produce
    # a COMPLETE snapshot: the old one or the new one, never a partial record set
    # and never an empty-success standing in for unreadable state.
    for boundary <- [:write, :file_sync, :close, :rename, :directory_sync] do
      test "an owner crash at #{boundary} reloads a complete old or new snapshot",
           %{root: root} do
        Process.flag(:trap_exit, true)

        {:ok, seed} = PaneIntentStore.start_link(root: root)
        :ok = PaneIntentStore.put(seed, record(@pane_1, root))
        stop_and_join!(seed)

        fs = new_fs()
        FaultFs.inject(fs, unquote(boundary), 1, {:hook, fn -> Process.exit(self(), :kill) end})
        {:ok, store} = PaneIntentStore.start_link(root: root, fs: fs)

        outcome =
          try do
            PaneIntentStore.put(store, record(@pane_2, root))
          catch
            :exit, _ -> :crashed
          end

        assert outcome == :crashed,
               "the owner must actually die at #{unquote(boundary)}, not return a value"

        {:ok, reloaded} = restart_owner!(root)
        assert {:ok, records} = PaneIntentStore.list(reloaded)
        ids = Enum.map(records, & &1["pane_id"])

        assert ids == [@pane_1] or ids == [@pane_1, @pane_2],
               "crash at #{unquote(boundary)} left a snapshot that is neither the old " <>
                 "nor the new one: #{inspect(ids)}"
      end
    end
  end

  # ============================================================ S1-F1-12

  describe "S1-F1-12 the unit is dormant in the running application" do
    test "the store is not started by the application supervision tree" do
      children =
        AiPair.Supervisor
        |> Process.whereis()
        |> case do
          nil -> []
          pid -> Supervisor.which_children(pid)
        end

      refute Enum.any?(children, fn {id, _, _, _} -> id == AiPair.PaneIntentStore end)
    end
  end

  # ------------------------------------------------- predicates under test
  # Self-contained on purpose: the reviewer extracts this block, rewrites defp to
  # def, compiles it standalone and runs the counterexamples below against it.
  # Nothing here may call a fixture helper.
  #
  # Records are `timeline/1` maps: %{op, args, disposition, value, attempt_at,
  # result_at}. Identity is PINNED by the caller and never adopted from the trace.

  defp pinned(new_state?), do: pinned_for("/private/tmp/probe", new_state?)

  defp pinned_for(root, new_state?) do
    state = Path.join(root, "state")

    %{
      root: root,
      state: state,
      final: Path.join(state, "pane-attachments.json"),
      new_state?: new_state?
    }
  end

  # Exact success shape per callback. "Any value that is not an error tuple" was a
  # success test that could not fail for nil, false or an arbitrary term.
  defp success?(:mkdir, :ok), do: true
  defp success?(:chmod, :ok), do: true
  defp success?(:write, :ok), do: true
  defp success?(:file_sync, :ok), do: true
  defp success?(:close, :ok), do: true
  defp success?(:rename, :ok), do: true
  defp success?(:directory_sync, :ok), do: true
  defp success?(:unlink, :ok), do: true
  defp success?(:open_exclusive, {:ok, _fd}), do: true
  defp success?(:lstat, {:ok, meta}), do: is_map(meta)
  defp success?(:read, {:ok, bytes}), do: is_binary(bytes)
  defp success?(_op, _value), do: false

  defp done?(%{disposition: :invoked} = r), do: success?(r.op, r.value)
  defp done?(_), do: false

  defp find(records, op, pred) do
    Enum.find(records, fn r -> r.op == op and done?(r) and pred.(r) end)
  end

  # An observed temporary path is adopted only after it is checked against the
  # pinned expectation. Adopting whatever the implementation opened made the
  # checker approve a same-directory violation by treating it as the expectation.
  defp adopt_temp(records, id) do
    candidate =
      Enum.find(records, fn r ->
        r.op == :open_exclusive and done?(r) and
          match?([p] when is_binary(p), r.args) and
          Path.dirname(hd(r.args)) == id.state and
          hd(r.args) != id.final and
          String.starts_with?(Path.basename(hd(r.args)), Path.basename(id.final) <> ".tmp")
      end)

    case candidate do
      nil -> :error
      %{args: [tmp], value: {:ok, fd}} -> {:ok, tmp, fd}
    end
  end

  defp durable_write_ok?(records, id) do
    with {:ok, tmp, fd} <- adopt_temp(records, id),
         open when not is_nil(open) <- find(records, :open_exclusive, &(&1.args == [tmp])),
         writes = [_ | _] <- content_writes(records, fd),
         true <- Enum.all?(writes, &done?/1),
         sync when not is_nil(sync) <- qualifying_sync(records, fd, writes),
         close when not is_nil(close) <- find(records, :close, &(&1.args == [fd])),
         rename when not is_nil(rename) <- find(records, :rename, &(&1.args == [tmp, id.final])),
         dsync when not is_nil(dsync) <- post_rename_state_sync(records, id, rename) do
      _ = dsync

      no_unresolved?(records) and
        after?(open, hd(writes)) and after?(sync, close) and after?(close, rename) and
        no_write_after?(records, fd, sync) and root_sync_ok?(records, id)
    else
      _ -> false
    end
  end

  # EVERY write on the descriptor, whatever its outcome. Filtering failures out
  # before checking completeness let a partial write vanish from the transaction:
  # an invoked write can return an error and still have performed part of its
  # effect, which this suite's own scripted torn-write control demonstrates. A
  # single non-successful write therefore invalidates the transaction outright,
  # because r3 requires a complete write and a swallowed error cannot prove one.
  defp content_writes(records, fd) do
    Enum.filter(records, &(&1.op == :write and &1.args != [] and hd(&1.args) == fd))
  end

  # Every content write must COMPLETE before the qualifying sync is ATTEMPTED.
  # Binding to the sync's ATTEMPT rather than its result is what excludes a write
  # that overlaps the sync and finishes while it is still in flight.
  defp qualifying_sync(records, fd, writes) do
    last_result = writes |> Enum.map(& &1.result_at) |> Enum.max()

    Enum.find(records, fn r ->
      r.op == :file_sync and done?(r) and r.args == [fd] and r.attempt_at > last_result
    end)
  end

  defp no_write_after?(records, fd, sync) do
    not Enum.any?(content_writes(records, fd), fn r -> r.attempt_at > sync.attempt_at end)
  end

  # Phase selection, not first-success position. An extra harmless earlier sync of
  # the state directory must not reject a transaction whose post-rename durability
  # edge is intact; frozen r3 forbids no such sync. This is the same defect class
  # as comparing rename to the FIRST directory_sync, which was corrected once and
  # reintroduced here.
  defp post_rename_state_sync(records, id, rename) do
    Enum.find(records, fn r ->
      r.op == :directory_sync and done?(r) and r.args == [id.state] and
        is_integer(rename.result_at) and r.attempt_at > rename.result_at
    end)
  end

  # A prerequisite's RESULT must precede its dependent's ATTEMPT. Both results
  # merely existing at the end does not establish that order.
  defp after?(prerequisite, dependent) do
    is_integer(prerequisite.result_at) and prerequisite.result_at < dependent.attempt_at
  end

  defp no_unresolved?(records), do: not Enum.any?(records, &(&1.disposition == :unresolved))

  defp root_sync_ok?(_records, %{new_state?: false}), do: true

  # Phase-selected for the same reason as the state sync: an extra earlier root
  # sync must not reject a valid transaction.
  defp root_sync_ok?(records, id) do
    case find(records, :mkdir, &(&1.args == [id.state])) do
      nil ->
        false

      mkdir ->
        Enum.any?(records, fn r ->
          r.op == :directory_sync and done?(r) and r.args == [id.root] and
            is_integer(mkdir.result_at) and r.attempt_at > mkdir.result_at
        end)
    end
  end

  # The mode in force at a position is the most recent SUCCESSFUL chmod on that
  # exact path whose result precedes it. Asking only whether a private chmod
  # happened somewhere earlier cannot fail for a disclosure window that is later
  # restored: 0600, then 0777, then content, then 0600 passed such a check while
  # exposing every byte written.
  defp effective_mode(records, path, position) do
    records
    |> Enum.filter(fn r ->
      r.op == :chmod and done?(r) and match?([^path, _], r.args) and
        is_integer(r.result_at) and r.result_at < position
    end)
    |> Enum.max_by(& &1.result_at, fn -> nil end)
    |> case do
      nil -> nil
      r -> List.last(r.args)
    end
  end

  # The observed end of the call. The qualifying post-rename directory sync is a
  # DURABILITY milestone, not the API return: after it, and before the call
  # returns, the published file still holds the bytes, so a mode loosened there
  # and restored before return was invisible to a window that closed at the sync.
  # Privacy therefore runs to the latest OBSERVED event in the trace.
  #
  # attempt_at is taken into account as well as result_at, so an UNRESOLVED
  # attempt - which has no result at all - still extends the window. A
  # result-only maximum silently drops exactly the operations whose outcome is
  # unknown, which are the ones least safe to exclude.
  defp observed_end(records) do
    records
    |> Enum.flat_map(fn r -> Enum.filter([r.attempt_at, r.result_at], &is_integer/1) end)
    |> Enum.max(fn -> nil end)
  end

  # No successful chmod may move the path off its private mode inside the window.
  # `from` nil means the whole transaction up to `to`.
  defp no_unsafe_chmod?(records, path, safe_mode, from, to) do
    not Enum.any?(records, fn r ->
      r.op == :chmod and done?(r) and match?([^path, _], r.args) and
        List.last(r.args) != safe_mode and
        is_integer(r.result_at) and r.result_at <= to and
        (is_nil(from) or r.result_at > from)
    end)
  end

  # Privacy is a property of the INTERVAL in which the owned file holds bytes, and
  # that interval follows the file's IDENTITY through publication: the bytes live
  # at the temporary path until the rename returns and at the final path
  # afterwards, until the transaction ends. Sampling the mode only where content
  # operations happen cannot see a window opened after a write returns and closed
  # before the next operation, because the file already holds the bytes and no
  # further content operation is needed for the exposure to be real. A
  # final-mode-only assertion cannot see it either, since the mode is restored.
  # The interval opens at temporary CREATION, not at the first write RESULT. A
  # write can perform part of its effect before the callback returns, so bytes may
  # exist while the write is still in flight; a mode loosened after the write's
  # attempt and restored before its result falls between an attempt-sampled point
  # check and a result-started interval, and both miss it. Starting at creation is
  # safe because "unsafe" means a chmod to a mode other than 0600, so the
  # establishing private chmod passes through the window rather than tripping it.
  defp temp_privacy_ok?(records, id) do
    with {:ok, tmp, fd} <- adopt_temp(records, id),
         open when not is_nil(open) <- find(records, :open_exclusive, &(&1.args == [tmp])),
         created when is_integer(created) <- open.result_at,
         writes = [_ | _] <- content_writes(records, fd) do
      rename = find(records, :rename, &(&1.args == [tmp, id.final]))
      last = observed_end(records)
      published = rename && rename.result_at

      is_integer(last) and
        Enum.all?(writes, fn w -> effective_mode(records, tmp, w.attempt_at) == 0o600 end) and
        no_unsafe_chmod?(records, tmp, 0o600, created, published || last) and
        (is_nil(published) or no_unsafe_chmod?(records, id.final, 0o600, published, last))
    else
      _ -> false
    end
  end

  # The owning directory stays private for the WHOLE transaction, not only at the
  # instants content is created. 0777 on the state directory exposes its entries
  # and directory write access; it does not override the file's own 0600, so this
  # is a directory-access violation rather than proof of file-byte disclosure.
  defp state_privacy_ok?(records, id) do
    with {:ok, tmp, fd} <- adopt_temp(records, id),
         content = [_ | _] <- content_ops_in_state(records, tmp, fd) do
      last = observed_end(records)

      is_integer(last) and
        Enum.all?(content, fn c -> effective_mode(records, id.state, c.attempt_at) == 0o700 end) and
        no_unsafe_chmod?(records, id.state, 0o700, nil, last)
    else
      _ -> false
    end
  end

  # Operations that create or extend content inside the state directory. Privacy
  # has to hold across all of them, not merely before the first.
  defp content_ops_in_state(records, tmp, fd) do
    Enum.filter(records, fn r ->
      (r.op == :open_exclusive and r.args == [tmp]) or
        (r.op == :write and r.args != [] and hd(r.args) == fd) or
        (r.op == :rename and match?([^tmp, _], r.args))
    end)
  end

  # --- named counterexamples, so the extraction can run them directly ---

  defp rec(op, args, value, attempt_at) do
    %{
      id: attempt_at,
      op: op,
      args: args,
      disposition: :invoked,
      value: value,
      attempt_at: attempt_at * 2,
      result_at: attempt_at * 2 + 1
    }
  end

  defp valid_records do
    i = pinned(true)
    tmp = Path.join(i.state, "pane-attachments.json.tmp-1")

    [
      rec(:lstat, [i.root], {:ok, %{type: :directory, mode: 0o700}}, 1),
      rec(:read, [i.final], {:ok, "{}"}, 2),
      rec(:mkdir, [i.state], :ok, 3),
      rec(:chmod, [i.state, 0o700], :ok, 4),
      rec(:directory_sync, [i.root], :ok, 5),
      rec(:open_exclusive, [tmp], {:ok, :fd1}, 6),
      rec(:chmod, [tmp, 0o600], :ok, 7),
      rec(:write, [:fd1, "bytes"], :ok, 8),
      rec(:file_sync, [:fd1], :ok, 9),
      rec(:close, [:fd1], :ok, 10),
      rec(:rename, [tmp, i.final], :ok, 11),
      rec(:directory_sync, [i.state], :ok, 12)
    ]
  end

  defp existing_state_records do
    i = pinned(true)
    Enum.reject(valid_records(), &(&1.op == :mkdir or &1.args == [i.root]))
  end

  defp omitted_root_sync do
    i = pinned(true)
    Enum.reject(valid_records(), &(&1.op == :directory_sync and &1.args == [i.root]))
  end

  defp wrong_synced_fd,
    do: change(valid_records(), :file_sync, fn r -> %{r | args: [:wrong_fd]} end)

  defp wrong_rename_target do
    change(valid_records(), :rename, fn r -> %{r | args: [hd(r.args), "/wrong/final"]} end)
  end

  defp wrong_synced_directories do
    change(valid_records(), :directory_sync, fn r -> %{r | args: ["/wrong/directory"]} end)
  end

  defp rename_before_fsync do
    records = valid_records()
    sync = Enum.find(records, &(&1.op == :file_sync))
    rename = Enum.find(records, &(&1.op == :rename))
    swapped = %{rename | attempt_at: sync.attempt_at - 1, result_at: sync.attempt_at - 1}
    Enum.map(records, fn r -> if r.op == :rename, do: swapped, else: r end)
  end

  defp refused_rename do
    change(valid_records(), :rename, fn r -> %{r | disposition: :refused, value: {:error, :eio}} end)
  end

  defp nil_sync_result, do: change(valid_records(), :file_sync, fn r -> %{r | value: nil} end)

  defp unsynced_later_write do
    records = valid_records()
    sync = Enum.find(records, &(&1.op == :file_sync))
    late = rec(:write, [:fd1, "unsynced replacement"], :ok, 0)
    late = %{late | attempt_at: sync.result_at + 1, result_at: sync.result_at + 2}
    records ++ [late]
  end

  defp sync_attempted_before_write_returned do
    records = valid_records()
    write = Enum.find(records, &(&1.op == :write))

    Enum.map(records, fn r ->
      if r.op == :file_sync, do: %{r | attempt_at: write.result_at - 1}, else: r
    end)
  end

  defp unresolved_write do
    change(valid_records(), :write, fn r ->
      %{r | disposition: :unresolved, value: nil, result_at: nil}
    end)
  end

  defp outside_state_temp do
    i = pinned(true)
    tmp = Path.join(i.state, "pane-attachments.json.tmp-1")

    Enum.map(valid_records(), fn r ->
      cond do
        r.op == :open_exclusive -> %{r | args: ["/outside/tmp-file"]}
        r.op == :chmod and r.args == [tmp, 0o600] -> %{r | args: ["/outside/tmp-file", 0o600]}
        r.op == :rename -> %{r | args: ["/outside/tmp-file", i.final]}
        true -> r
      end
    end)
  end

  defp temp_equals_final do
    i = pinned(true)
    change(valid_records(), :open_exclusive, fn r -> %{r | args: [i.final]} end)
  end

  defp wrong_temp_mode do
    change_where(valid_records(), fn r -> r.op == :chmod and List.last(r.args) == 0o600 end, fn r ->
      %{r | args: [hd(r.args), 0o777]}
    end)
  end

  defp wrong_state_chmod_path do
    change_where(valid_records(), fn r -> r.op == :chmod and List.last(r.args) == 0o700 end, fn r ->
      %{r | args: ["/unrelated", 0o700]}
    end)
  end

  defp missing_temp_chmod do
    Enum.reject(valid_records(), fn r -> r.op == :chmod and List.last(r.args) == 0o600 end)
  end

  # C1-C3 transaction-order counterexamples.
  # Positions are widened so records can be inserted while keeping a realizable
  # total order, matching the reviewer's construction.

  defp spaced_records do
    Enum.map(valid_records(), &%{&1 | attempt_at: &1.attempt_at * 10, result_at: &1.result_at * 10})
  end

  defp insert(records, r), do: Enum.sort_by([r | records], & &1.attempt_at)

  defp partial_write_overlapping_sync do
    v = spaced_records()
    sync = Enum.find(v, &(&1.op == :file_sync))

    insert(v, %{
      rec(:write, [:fd1, "partial"], {:error, :torn_write}, 999)
      | attempt_at: sync.attempt_at + 1,
        result_at: sync.result_at + 1
    })
  end

  defp partial_write_before_sync do
    v = spaced_records()
    write = Enum.find(v, &(&1.op == :write))

    insert(v, %{
      rec(:write, [:fd1, "partial"], {:error, :torn_write}, 999)
      | attempt_at: write.result_at + 1,
        result_at: write.result_at + 2
    })
  end

  defp temp_unsafe_during_write do
    v = spaced_records()
    write = Enum.find(v, &(&1.op == :write))
    {:ok, tmp, _fd} = adopt_temp(v, pinned(true))

    v
    |> insert(%{
      rec(:chmod, [tmp, 0o777], :ok, 998)
      | attempt_at: write.attempt_at - 2,
        result_at: write.attempt_at - 1
    })
    |> insert(%{
      rec(:chmod, [tmp, 0o600], :ok, 997)
      | attempt_at: write.result_at + 1,
        result_at: write.result_at + 2
    })
  end

  defp state_unsafe_during_content do
    v = spaced_records()
    i = pinned(true)
    open = Enum.find(v, &(&1.op == :open_exclusive))
    write = Enum.find(v, &(&1.op == :write))

    v
    |> insert(%{
      rec(:chmod, [i.state, 0o777], :ok, 998)
      | attempt_at: open.attempt_at - 2,
        result_at: open.attempt_at - 1
    })
    |> insert(%{
      rec(:chmod, [i.state, 0o700], :ok, 997)
      | attempt_at: write.result_at + 1,
        result_at: write.result_at + 2
    })
  end

  defp extra_state_sync_before_open do
    v = spaced_records()
    i = pinned(true)
    open = Enum.find(v, &(&1.op == :open_exclusive))

    insert(v, %{
      rec(:directory_sync, [i.state], :ok, 996)
      | attempt_at: open.attempt_at - 2,
        result_at: open.attempt_at - 1
    })
  end

  defp create_before_state_chmod do
    records = valid_records()
    chmod = Enum.find(records, fn r -> r.op == :chmod and List.last(r.args) == 0o700 end)
    open = Enum.find(records, &(&1.op == :open_exclusive))

    Enum.map(records, fn r ->
      if r.op == :chmod and List.last(r.args) == 0o700 do
        %{chmod | attempt_at: open.result_at + 1, result_at: open.result_at + 2}
      else
        r
      end
    end)
  end

  # D1 owned-file privacy counterexamples.
  # All three are fully sequential and same-owner: no hostile replacement, no
  # concurrent actor, no external process. The exposure needs no further content
  # operation, because the bytes are already there once the write has returned.

  defp temp_unsafe_between_operations do
    v = spaced_records()
    {:ok, tmp, _fd} = adopt_temp(v, pinned(true))
    write = Enum.find(v, &(&1.op == :write))
    sync = Enum.find(v, &(&1.op == :file_sync))

    v
    |> insert(%{
      rec(:chmod, [tmp, 0o777], :ok, 995)
      | attempt_at: write.result_at + 1,
        result_at: write.result_at + 2
    })
    |> insert(%{
      rec(:chmod, [tmp, 0o600], :ok, 994)
      | attempt_at: sync.result_at + 1,
        result_at: sync.result_at + 2
    })
  end

  defp state_unsafe_between_operations do
    v = spaced_records()
    i = pinned(true)
    write = Enum.find(v, &(&1.op == :write))
    sync = Enum.find(v, &(&1.op == :file_sync))

    v
    |> insert(%{
      rec(:chmod, [i.state, 0o777], :ok, 995)
      | attempt_at: write.result_at + 1,
        result_at: write.result_at + 2
    })
    |> insert(%{
      rec(:chmod, [i.state, 0o700], :ok, 994)
      | attempt_at: sync.result_at + 1,
        result_at: sync.result_at + 2
    })
  end

  # The rename-to-publication interval: the same bytes, now at the final path.
  defp final_unsafe_after_rename do
    v = spaced_records()
    i = pinned(true)
    rename = Enum.find(v, &(&1.op == :rename))

    v
    |> insert(%{
      rec(:chmod, [i.final, 0o777], :ok, 993)
      | attempt_at: rename.result_at + 1,
        result_at: rename.result_at + 2
    })
    |> insert(%{
      rec(:chmod, [i.final, 0o600], :ok, 992)
      | attempt_at: rename.result_at + 3,
        result_at: rename.result_at + 4
    })
  end

  # In-flight window: opened after the write is ATTEMPTED and closed before it
  # RETURNS. The state predicate's window spans the whole transaction.

  defp temp_unsafe_during_inflight_write do
    v = spaced_records()
    {:ok, tmp, _fd} = adopt_temp(v, pinned(true))
    write = Enum.find(v, &(&1.op == :write))

    v
    |> insert(%{
      rec(:chmod, [tmp, 0o777], :ok, 991)
      | attempt_at: write.attempt_at + 1,
        result_at: write.attempt_at + 2
    })
    |> insert(%{
      rec(:chmod, [tmp, 0o600], :ok, 990)
      | attempt_at: write.result_at - 2,
        result_at: write.result_at - 1
    })
  end

  defp state_unsafe_during_inflight_write do
    v = spaced_records()
    i = pinned(true)
    write = Enum.find(v, &(&1.op == :write))

    v
    |> insert(%{
      rec(:chmod, [i.state, 0o777], :ok, 991)
      | attempt_at: write.attempt_at + 1,
        result_at: write.attempt_at + 2
    })
    |> insert(%{
      rec(:chmod, [i.state, 0o700], :ok, 990)
      | attempt_at: write.result_at - 2,
        result_at: write.result_at - 1
    })
  end

  # Observed-call endpoint. These windows open AFTER the
  # qualifying post-rename directory sync and close before the call returns.
  # The third is a MUST-PASS control: extending the endpoint must not
  # turn into rejecting every post-sync chmod.

  defp final_unsafe_after_sync do
    v = spaced_records()
    i = pinned(true)
    last = observed_end(v)

    v
    |> insert(%{
      rec(:chmod, [i.final, 0o777], :ok, 989)
      | attempt_at: last + 1,
        result_at: last + 2
    })
    |> insert(%{
      rec(:chmod, [i.final, 0o600], :ok, 988)
      | attempt_at: last + 3,
        result_at: last + 4
    })
  end

  defp state_unsafe_after_sync do
    v = spaced_records()
    i = pinned(true)
    last = observed_end(v)

    v
    |> insert(%{
      rec(:chmod, [i.state, 0o777], :ok, 989)
      | attempt_at: last + 1,
        result_at: last + 2
    })
    |> insert(%{
      rec(:chmod, [i.state, 0o700], :ok, 988)
      | attempt_at: last + 3,
        result_at: last + 4
    })
  end

  defp harmless_private_final_chmod_after_sync do
    v = spaced_records()
    i = pinned(true)
    last = observed_end(v)

    insert(v, %{rec(:chmod, [i.final, 0o600], :ok, 987) | attempt_at: last + 1, result_at: last + 2})
  end

  defp change(records, op, fun), do: change_where(records, &(&1.op == op), fun)

  defp change_where(records, pred, fun) do
    Enum.map(records, fn r -> if pred.(r), do: fun.(r), else: r end)
  end

  # ------------------------------------------------- fixtures

  defp canonical_tmp do
    System.tmp_dir!()
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce("/", fn seg, acc ->
      joined = Path.join(acc, seg)

      case File.read_link(joined) do
        {:ok, "/" <> _ = absolute} -> absolute
        {:ok, relative} -> Path.expand(Path.join(Path.dirname(joined), relative))
        {:error, _} -> joined
      end
    end)
  end

  defp symlink_ancestors(path) do
    path
    |> Path.split()
    |> Enum.scan(fn part, acc -> Path.join(acc, part) end)
    |> Enum.filter(&match?({:ok, %{type: :symlink}}, File.lstat(&1)))
  end

  defp mode_of(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  # Both doubles stop with `if Process.alive?(agent), do: Agent.stop(agent)`,
  # which is check-then-act: the agent can die between the guard and the call,
  # and Agent.stop then exits :noproc. That surfaced once in roughly five async
  # runs as a TEARDOWN failure on an unrelated row - the body had already passed.
  # It is a flake, and a flake is not a pass: a reviewer running the suite once
  # could see red on a candidate reported green.
  #
  # The double is byte-identical since r4 and the B1/B3/A4 proofs carry on those
  # exact bytes, so the tolerance belongs here rather than in the double. It is
  # deliberately narrow - only "the agent is already gone" is swallowed, so a
  # genuine teardown hang or crash still fails loudly.
  defp stop_if_running(fun) do
    fun.()
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
  end

  # Race-free teardown for an owned process fixture, and the general form of the
  # lesson the comment above only half-applied.
  #
  # `if Process.alive?(pid), do: stop(pid)` is check-then-act: the process can
  # exit between the guard and the call. The stop then exits :noproc - or, for a
  # supervisor whose linked owner is going away, :shutdown. That produced a
  # roughly 1-in-4 TEARDOWN failure on the supervision row in the FULL suite
  # while passing every time in isolation, which is the worst shape of flake:
  # invisible to the focused run a producer looks at.
  #
  # Having written that comment, I then used the same shape in three more rows of
  # this file. Recording a lesson is not applying it.
  #
  # This monitors FIRST, so a process that has already exited simply delivers
  # :noproc and the join is awaited either way. Only benign terminal reasons are
  # tolerated; a genuine hang still fails loudly on the timeout.
  # There is deliberately no stop/1 call here, and no catch.
  #
  # A first attempt wrapped GenServer.stop in try/catch and enumerated the exit
  # reasons it expected. That failed: the real term nests, so the first element
  # is {:shutdown, {:sys, :terminate, _}} rather than the bare atom :shutdown,
  # and neither guard matched. Guessing an exit shape and guessing wrong is the
  # same defect as guessing a parser shape.
  #
  # Process.exit/2 never raises, so there is no exit term left to classify: the
  # failure mode is removed rather than enumerated. :shutdown is the graceful
  # signal a supervisor handles, and the monitored join still PROVES termination
  # instead of assuming it. This is the shape of reclaim/1 below, which has been
  # in this file throughout and has never flaked.
  defp join_owned!(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :shutdown)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      5_000 ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          2_000 -> raise "owned fixture #{inspect(pid)} could not be joined"
        end
    end
  end

  defp new_fs do
    fs = FaultFs.new()
    on_exit(fn -> stop_if_running(fn -> FaultFs.stop(fs) end) end)
    fs
  end

  defp scripted_fs do
    backend = ScriptedBackend.new()
    fs = FaultFs.new(backend: backend)
    on_exit(fn -> stop_if_running(fn -> FaultFs.stop(fs) end) end)
    on_exit(fn -> stop_if_running(fn -> ScriptedBackend.stop(backend) end) end)
    {fs, backend}
  end

  defp spawn_barriered_owner! do
    parent = self()

    owner =
      spawn(fn ->
        {_mod, agent} = FaultFs.new()
        send(parent, {:agent, self(), agent})
        receive do: (:fail_now -> :ok)
        raise "forced owned-fixture failure"
      end)

    on_exit(fn -> reclaim(owner) end)

    receive do
      {:agent, ^owner, agent} ->
        on_exit(fn -> reclaim(agent) end)
        {owner, agent}
    after
      1_000 ->
        reclaim(owner)
        flunk("owner never published its tracer")
    end
  end

  defp reclaim_helper!(owner, agent) do
    :ok = reclaim(owner)
    :ok = reclaim(agent)
    :ok
  end

  defp reclaim(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        2_000 -> flunk("owned helper #{inspect(pid)} could not be reclaimed")
      end
    else
      :ok
    end
  end

  # H3-A. A census must distinguish ABSENCE from FAILURE.
  #
  # The previous helper discarded lsof's exit status and substring-matched whole
  # lines. An independently extracted copy scored 1 positive PASS and 3 negative
  # FAIL against scripted output: a status-1 failure counted as zero descriptors
  # and so read as successful reclamation; a prefix neighbour `/x/state-other`
  # counted as `/x/state`; and a `cwd` record counted as an opened descriptor.
  # The first of those is the dangerous one - it made the after-DOWN assertion
  # unable to fail in the direction that matters.
  #
  # This returns {:ok, count} or {:error, reason}. Uncertainty is NEVER zero, the
  # job is bounded, and there is no retry-until-absence loop: a census that could
  # not be taken is an error, not evidence of a reclaimed descriptor.
  # === CENSUS-HELPER-BEGIN ===
  # Everything between these markers is the resource oracle. The post-error
  # probe EXTRACTS this exact block rather than reimplementing it, so what the
  # probe exercises and what the healthy suite uses are the same code. A
  # handwritten copy proved nothing about the shipped helper, however carefully
  # it was written.
  @census_timeout 5_000

  # Builds scripted field output bound to THIS process, so the controls exercise
  # the same identity check a live census does.
  defp field_census(records, status \\ 0) do
    fn -> {"p#{:os.getpid()}\n" <> records, status} end
  end

  # Joins an owned caller fixture on BOTH paths. Asking a process to stop is not
  # teardown unless its termination is observed: if it does not exit promptly it
  # is killed, and either way the DOWN is awaited, so no late timer can be
  # mistaken for cleanup.
  #
  # There is deliberately no Process.alive?/1 guard before the monitor. That
  # check-then-act shape is what produced the flaky teardown earlier in this
  # suite; monitoring a process that has already exited simply delivers :noproc.
  defp reclaim_caller!(caller) do
    ref = Process.monitor(caller)
    send(caller, :stop)

    receive do
      {:DOWN, ^ref, :process, ^caller, _reason} -> :ok
    after
      500 ->
        Process.exit(caller, :kill)

        receive do
          {:DOWN, ^ref, :process, ^caller, _reason} -> :ok
        after
          2_000 -> raise "owned caller fixture could not be joined"
        end
    end
  end

  # The census reads STRUCTURED output (`lsof -F pfn`), not display columns.
  #
  # Three defects made the previous parser unable to fail in the direction that
  # matters, and the field format fixes all three at once:
  #
  #   * a tool exiting 0 with empty, truncated or malformed bytes was counted as
  #     ZERO descriptors and read as successful reclamation. Grammar validation
  #     now makes unusable output an ERROR - only a WELL-FORMED, complete census
  #     with no matching record may legitimately report zero;
  #   * output was never bound to the expected process, so another process's
  #     records would have been accepted. The leading `p` record must be our own
  #     OS pid;
  #   * exact pathname equality can lose an owned descriptor once its file is
  #     unlinked, on platforms that report the name with a "(deleted)" suffix.
  #     MEASURED here: macOS does NOT - it keeps the plain resolved pathname,
  #     unchanged by the unlink - so that branch is portability headroom and the
  #     plain branch is what detects the unlinked case on this platform. An
  #     earlier revision of this bullet stated the suffix as fact, and an earlier
  #     revision of the code "solved" the problem by observing before the unlink,
  #     which fixed the POSITIVE observation and left the NEGATIVE one unable to
  #     tell a reclaimed descriptor from a still-open unlinked one;
  #   * completeness was inferred from SPLITTING, so a final field that never
  #     received its terminator parsed as a complete record. Framing is now
  #     validated before the split.
  #
  # Records are `p<pid>`, `f<fd>`, `n<name>`; an `n` is the name of the `f` that
  # precedes it. Parser uncertainty is never successful absence.
  defp dir_fd_census(target, census \\ &run_fd_census/0) do
    case census.() do
      {out, 0} when is_binary(out) -> parse_census(out, target)
      {_out, status} when is_integer(status) -> {:error, {:census_exit_status, status}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:census_unparseable, other}}
    end
  end

  defp parse_census(out, target) do
    with :ok <- census_terminated(out),
         lines = String.split(out, "\n", trim: true),
         :ok <- census_nonempty(lines),
         :ok <- census_process_identity(lines),
         {:ok, fds} <- census_records(lines, to_string(:os.getpid())) do
      {:ok, Enum.count(fds, fn {fd, name} -> owned_descriptor?(fd, name, target) end)}
    end
  end

  # Framing is validated BEFORE splitting, because splitting DISCARDS it.
  #
  # `String.split(_, "\n", trim: true)` presents a final field that never
  # received its terminator exactly as if it were complete. Output truncated
  # mid-name therefore parsed as a complete NON-MATCHING record and returned
  # {:ok, 0}: truncation reading as absence one last time, through the only
  # channel the record state machine cannot see, because completeness was
  # inferred from the split rather than observed from the terminator.
  #
  # An empty observation stays :census_empty - only a non-empty one is required
  # to be terminated - so this adds a guard without reopening the record machine
  # or weakening complete-no-match.
  defp census_terminated(""), do: :ok

  defp census_terminated(out) do
    if String.ends_with?(out, "\n"),
      do: :ok,
      else: {:error, {:census_incomplete, :unterminated_final_field}}
  end

  defp census_nonempty([]), do: {:error, :census_empty}
  defp census_nonempty(_lines), do: :ok

  defp census_process_identity([<<?p, pid::binary>> | _rest]) do
    if pid == to_string(:os.getpid()), do: :ok, else: {:error, {:census_wrong_process, pid}}
  end

  defp census_process_identity([other | _rest]), do: {:error, {:census_malformed, other}}

  # Every line must be a field record, and a name must belong to a descriptor.
  defp census_records(lines, expected_pid) do
    lines
    |> Enum.reduce_while({:ok, {:awaiting_fd, []}}, fn line, {:ok, {state, acc}} ->
      case {line, state} do
        {<<?p, pid::binary>>, :awaiting_fd} ->
          if pid == expected_pid do
            {:cont, {:ok, {:awaiting_fd, acc}}}
          else
            {:halt, {:error, {:census_wrong_process, pid}}}
          end

        {<<?p, _::binary>>, {:awaiting_name, fd}} ->
          {:halt, {:error, {:census_incomplete, {:descriptor_without_name, fd}}}}

        {"f", _any} ->
          {:halt, {:error, {:census_malformed, :empty_descriptor}}}

        {<<?f, fd::binary>>, :awaiting_fd} ->
          if census_fd_supported?(fd) do
            {:cont, {:ok, {{:awaiting_name, fd}, acc}}}
          else
            {:halt, {:error, {:census_malformed, {:unsupported_descriptor, fd}}}}
          end

        {<<?f, _::binary>>, {:awaiting_name, fd}} ->
          {:halt, {:error, {:census_incomplete, {:descriptor_without_name, fd}}}}

        {"n", _any} ->
          {:halt, {:error, {:census_malformed, :empty_name}}}

        {<<?n, name::binary>>, {:awaiting_name, fd}} ->
          {:cont, {:ok, {:awaiting_fd, [{fd, name} | acc]}}}

        {<<?n, _::binary>>, :awaiting_fd} ->
          {:halt, {:error, {:census_malformed, :name_without_descriptor}}}

        {other, _any} ->
          {:halt, {:error, {:census_malformed, other}}}
      end
    end)
    |> case do
      {:ok, {:awaiting_fd, acc}} ->
        {:ok, Enum.reverse(acc)}

      # Unfinished at end of output: the census was truncated mid-record, and a
      # prefix of a record must never be counted as a complete observation.
      {:ok, {{:awaiting_name, fd}, _acc}} ->
        {:error, {:census_incomplete, {:descriptor_without_name, fd}}}

      {:error, _reason} = error ->
        error
    end
  end

  # A NUMERIC descriptor on the target. cwd, txt and rtd records are not open
  # descriptors, and with field output the numeric test belongs on the FD field.
  #
  # Worth recording: a first draft of this very block put that test on the NAME
  # and made it unconditionally true, which would have re-admitted the cwd defect
  # inside the fix written for it. An always-true predicate with a checking name
  # is the same failure the census itself was rejected for.
  #
  # The deleted representation is accepted DELIBERATELY: it is the same owned
  # resource, and treating it as absence is how an unlinked-but-open descriptor
  # would get reported reclaimed.
  #
  # Measured, so the claim is not overstated: on THIS platform lsof reports an
  # unlinked-but-open file under its plain resolved pathname, unchanged by the
  # unlink - so the plain branch is what detects the unlinked case here, and the
  # deleted branch is portability headroom for platforms that do suffix. An
  # earlier revision of this comment implied the deleted branch was the
  # mechanism; removing it changes nothing on macOS, which is how that was found.
  defp owned_descriptor?(fd, name, target) do
    census_fd_numeric?(fd) and (name == target or name == target <> " (deleted)")
  end

  defp census_fd_numeric?(fd), do: Regex.match?(~r/^\d+$/, fd)

  # Numeric descriptors are open FDs. lsof also emits documented PSEUDO
  # descriptors, and those are classified EXPLICITLY rather than silently
  # ignored - otherwise an arbitrary bad token would masquerade as a legitimate
  # pseudo record, and malformed output would look merely uninteresting.
  @census_pseudo_fds ~w(cwd txt rtd mem mmap ltx jld tr err ctty pd twd DEL)

  defp census_fd_supported?(fd), do: census_fd_numeric?(fd) or fd in @census_pseudo_fds

  # Resolved through the platform toolchain rather than a hardcoded /usr/sbin
  # path, which would prove nothing on Linux. An absent tool is an ERROR.
  defp run_fd_census do
    case System.find_executable("lsof") do
      nil -> {:error, :census_tool_unavailable}
      exe -> run_bounded_census(exe, ["-F", "pfn", "-p", to_string(:os.getpid())])
    end
  end

  # A Task timeout kills the BEAM task and leaves the spawned OS command running:
  # the reviewer demonstrated the child completing its work AFTER the census had
  # already reported a timeout. A port gives the child's os_pid, so the timeout
  # path can terminate it and then CONFIRM its absence by signal-zero rather than
  # assume it. The join outcome is returned so a control can assert on it.
  defp run_bounded_census(exe, args, timeout \\ @census_timeout) do
    port = Port.open({:spawn_executable, exe}, [:binary, :exit_status, :hide, args: args])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    deadline = System.monotonic_time(:millisecond) + timeout
    collect_census(port, os_pid, deadline, [])
  end

  defp collect_census(port, os_pid, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      bound_census_child(port, os_pid)
    else
      receive do
        {^port, {:data, chunk}} -> collect_census(port, os_pid, deadline, [acc, chunk])
        {^port, {:exit_status, status}} -> {IO.iodata_to_binary(acc), status}
      after
        remaining -> bound_census_child(port, os_pid)
      end
    end
  end

  defp bound_census_child(port, os_pid) do
    _ =
      try do
        Port.close(port)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end

    {:error, {:census_timed_out, os_pid, join_os_child(os_pid)}}
  end

  # Terminate the OWNED child and observe that it is gone. Absence is confirmed,
  # not inferred from having sent a signal.
  defp join_os_child(os_pid, query \\ &os_existence_query/1)

  defp join_os_child(nil, _query), do: :no_child

  defp join_os_child(os_pid, query) do
    _ = System.cmd("/bin/kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)
    await_os_absence(os_pid, System.monotonic_time(:millisecond) + 2_000, query)
  end

  defp os_existence_query(os_pid),
    do: System.cmd("/bin/kill", ["-0", to_string(os_pid)], stderr_to_stdout: true)

  # A failed QUERY is not absence.
  #
  # The previous version mapped EVERY non-zero status to {:joined, _}, which is
  # the census's own absence-versus-failure confusion reproduced one layer down
  # in the join: a permission error or a missing tool would have certified the
  # child gone. Only "no such process" establishes absence; anything else is
  # :unknown, and the caller must treat it as uncertainty.
  defp await_os_absence(os_pid, deadline, query) do
    case query.(os_pid) do
      {_out, 0} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:not_joined, os_pid}
        else
          Process.sleep(10)
          await_os_absence(os_pid, deadline, query)
        end

      {out, _nonzero} ->
        if String.contains?(String.downcase(out), "no such process") do
          {:joined, os_pid}
        else
          {:unknown, os_pid, String.trim(out)}
        end
    end
  end

  # === CENSUS-HELPER-END ===

  defp stop_and_join!(pid) do
    ref = Process.monitor(pid)
    :ok = GenServer.stop(pid, :normal, 5_000)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    :ok
  end

  # A barrier, not a sleep. The owner is blocked inside a seam hook, so a second
  # caller's request can only be sitting in its mailbox; this observes that fact
  # rather than guessing how long it takes to arrive.
  defp await_queued(pid, at_least \\ 1, attempts \\ 2_000) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, n} when n >= at_least -> {:halt, true}
        nil -> {:halt, false}
        _ -> {:cont, false}
      end
    end)
  end

  # :global releases a dead owner's name asynchronously, so a restart immediately
  # after a crash can legitimately see :ownership for a moment. Retrying on that
  # one stage only - never on any other error - waits for the release without
  # sleeping and without masking a real refusal.
  defp restart_owner!(root, attempts \\ 500) do
    1..attempts
    |> Enum.reduce_while(nil, fn _, _ ->
      case PaneIntentStore.start_link(root: root) do
        {:ok, pid} -> {:halt, {:ok, pid}}
        {:error, %{stage: :ownership}} -> {:cont, nil}
        {:error, other} -> {:halt, {:error, other}}
      end
    end)
    |> case do
      {:ok, pid} -> {:ok, pid}
      other -> flunk("owner did not restart after crash: #{inspect(other)}")
    end
  end

  # Whether a binary is ALREADY an atom, without creating one. Used as a
  # precondition as well as an assertion: a witness that the value is not
  # interned means nothing unless the value was fresh to begin with.
  defp atom_exists?(value) do
    _ = String.to_existing_atom(value)
    true
  rescue
    ArgumentError -> false
  end

  defp state_path(root), do: Path.join([root, "state", "pane-attachments.json"])

  defp seed_state!(root, contents) do
    state = Path.join(root, "state")
    File.mkdir_p!(state)
    File.chmod!(state, 0o700)
    File.write!(state_path(root), contents)
    File.chmod!(state_path(root), 0o600)
    assert mode_of(state) == 0o700
    assert mode_of(state_path(root)) == 0o600
    :ok
  end

  defp envelope(attachments) do
    Jason.encode!(%{
      "schema_version" => "1.0",
      "updated_at" => "2026-09-11T00:00:00Z",
      "attachments" => attachments
    })
  end

  defp record(pane_id, root, overrides \\ %{}) do
    Map.merge(
      %{
        "schema_version" => "1.0",
        "pane_id" => pane_id,
        "agent" => "claude_code",
        "classifier" => "fingerprint:claude_code",
        "project" => "demo",
        "project_dir" => "/workspace/demo",
        "project_inbox" => root,
        "tmux_session" => "ai-pair/demo",
        "session_gen" => "2",
        "cwd" => "/workspace/demo",
        "command" => "claude",
        "pane_pid" => 4242,
        "updated_at" => "2026-09-11T00:00:00Z"
      },
      overrides
    )
  end
end
