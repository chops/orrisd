defmodule AiPair.RedactionArtifactClassTest do
  @moduledoc """
  NS-30.M.002, failure control "Seed secret into each artifact class; broad
  exclusions cannot hide it".

  This file drives the real scanner, `bin/redaction-check`, as a child process. It
  seeds one secret into each of five artifact classes and shows that:

    * the scanner reports the secret;
    * an exact allowlist entry hides only its own finding;
    * the same value at a new path is a new finding;
    * no broad allowlist spelling can hide the finding.

  Each class is scanned two ways:

    * as a loose tree passed with `--paths`. Findings are labelled
      `<external-N>/<relative path>`;
    * as git-tracked files in a temporary repository, using the default tracked
      mode. Findings are labelled with the repository-relative path.

  ## The five artifact classes

  All five are SYNTHETIC FIXTURES. Each is written at run time into a temporary
  directory, at the relative path of the store it models. No real store is read.
  The real stores are OUT-OF-TREE under the daemon inbox (default
  `~/.ai-agent-inbox/ai-pair`, see `lib/ai_pair/inbox.ex`) and may hold operator
  data, so this test never points the scanner at them. The scanner has no special
  knowledge of any store; it sees these files exactly as it would see the real
  ones if they were passed with `--paths` or committed.

  Orrisd's own artifact stores, at the paths the product writes:

    1. `delivery/receipts.jsonl`: the delivery receipt log
       (`lib/ai_pair/delivery/receipt_log.ex:12-13`). Seeded with a
       `github_token`.
    2. `state/pane-attachments.json`: the pane-intent store
       (`lib/ai_pair/pane_intent_store.ex:74`). Seeded with an
       `aws_access_key`.
    3. `state/boot-report.json`: the durable boot report
       (`lib/ai_pair/pane_restore/boot.ex:191`). Seeded with a `slack_token`.

  Orris class shapes, for the categories Orrisd has no store of its own for. The
  names are those pinned from Orris main
  `24eee05a3a081923c2e7c5e2e4a61b95e6c09ec9` in
  `test/ai_pair/contracts/cross_product_boundary_test.exs`:

    4. `events.jsonl`: the Orris event log. Seeded with an `anthropic_token`.
    5. `pane-claims/claim.json`: the Orris pane-claim registry. Seeded with a
       `gitlab_token`.

  Every secret is assembled at run time from fragments, as the scanner and its
  shell test do. So this source file contains no scannable value, and the
  repository scan (`bin/verify:63`) stays clean.

  ## Cases

  For each class and each scan mode:

    * bare: exit status exactly 1; exactly one finding line
      `<label>:<line>:<pattern>` followed by `redaction-check: 1 finding(s)` on
      stderr. With `--locators`, stdout carries the locator
      `<pattern>:<label>:<sha256 of the match>`, and the digest is recomputed
      here independently;
    * exact entry: exit 0, `redaction-check: clean`, no stderr;
    * exact entry plus the same value at a new path: exit 1, exactly one finding,
      naming the NEW path;
    * seven broad spellings, each alone: every one still exits 1 with the
      finding. The spellings are:
      - `*`
      - `<pattern>:*`
      - `<pattern>:<path>`
      - `<pattern>:<path>:*`
      - `*:<path>:<digest>`
      - `<pattern>:<dir>/*:<digest>`
      - `<path>`

  Across classes, one scan of all five with only class 1's exact entry reports
  exactly the other four. The repository's own `.redaction-allow` must contain
  no broad entry: every entry is `<pattern>:<path>:<64-hex digest>` with no glob
  character. The same predicate is self-checked against the seven spellings and
  against the exact entries this file builds. The neutral clean baseline is all
  five classes with a `REDACTED` placeholder instead of a secret: exit 0, stdout
  exactly `redaction-check: clean`, and empty stderr, in both modes.

  ## Process containment

  Every scanner and git invocation runs under coreutils `timeout
  --kill-after=5s 60s`, as `test/ai_pair/ipc/sessions_test.exs` does, so a hung
  child cannot hold the suite. stdout is captured by `System.cmd`. stderr is
  redirected by a `bash -c` wrapper to a per-call file, read back, and deleted.
  Git runs with `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1`, so no
  operator configuration is read. Every temporary tree and repository is
  uniquely named and removed in `on_exit`, which also runs when a test fails.

  ## Gate placement

  This file is intentionally NOT hash-pinned by `bin/verify`. The pinned pair is
  the scanner and `test/redaction_check_test.sh` (`bin/verify:46-62`). This file
  is included through the ordinary `mix test` step (`bin/verify:66`), so editing
  it does not require changing the gate.

  ## Limits

    * The classes are synthetic files at the stores' relative paths. The test does
      not show that a real, live store is scanned by any gate step. `bin/verify`
      scans only tracked repository files, and the real stores are out-of-tree.
    * One secret pattern per class. Every pattern matching in every class is not
      claimed here; pattern coverage is the pinned shell test's job.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @scanner Path.join(@root, "bin/redaction-check")
  @repo_allowlist Path.join(@root, ".redaction-allow")

  @class_ids [:receipts, :pane_intents, :boot_report, :orris_events, :orris_pane_claims]

  # ---------------------------------------------------------------- classes

  # Secrets are assembled from fragments so this file holds no scannable value.
  defp class(:receipts) do
    secret = "g" <> "hp_" <> String.duplicate("Ns30M002Rc", 4)

    %{
      path: "delivery/receipts.jsonl",
      pattern: "github_token",
      body: fn value ->
        ~s({"schema":"ai_pair.receipt","seq":1,"status":"delivered","note":"#{value}"}\n)
      end,
      secret: secret
    }
  end

  defp class(:pane_intents) do
    secret = "A" <> "KIA" <> "NS30M002PANEINTS"

    %{
      path: "state/pane-attachments.json",
      pattern: "aws_access_key",
      body: fn value ->
        ~s({"schema_version":"1.0","attachments":{"a":{"command":"env KEY=#{value} agent"}}}\n)
      end,
      secret: secret
    }
  end

  defp class(:boot_report) do
    secret = "x" <> "oxb-" <> "ns30-m002-boot-report-000"

    %{
      path: "state/boot-report.json",
      pattern: "slack_token",
      body: fn value -> ~s({"generation":"1","rows":[{"reason":"#{value}"}]}\n) end,
      secret: secret
    }
  end

  defp class(:orris_events) do
    secret = "s" <> "k-ant-" <> "ns30_m002_orris_events_0000"

    %{
      path: "events.jsonl",
      pattern: "anthropic_token",
      body: fn value -> ~s({"type":"dispatch","payload":"#{value}"}\n) end,
      secret: secret
    }
  end

  defp class(:orris_pane_claims) do
    secret = "g" <> "lpat-" <> "ns30_m002_pane_claims_00"

    %{
      path: "pane-claims/claim.json",
      pattern: "gitlab_token",
      body: fn value -> ~s({"claim":"c1","owner_env":"#{value}"}\n) end,
      secret: secret
    }
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  # ---------------------------------------------------------------- broad entries

  defp broad_spellings(pattern, path, digest) do
    dir = Path.dirname(path)

    [
      "*",
      "#{pattern}:*",
      "#{pattern}:#{path}",
      "#{pattern}:#{path}:*",
      "*:#{path}:#{digest}",
      "#{pattern}:#{dir}/*:#{digest}",
      path
    ]
  end

  # An entry is exact only as <pattern>:<path>:<64 lowercase hex>, with no glob
  # character anywhere.
  defp broad_entry?(locator) do
    not (Regex.match?(~r/\A[a-z_]+:[^:\s]+:[0-9a-f]{64}\z/, locator) and
           not String.contains?(locator, ["*", "?", "["]))
  end

  # ---------------------------------------------------------------- per class

  for id <- @class_ids, mode <- [:paths, :git] do
    @id id
    @mode mode

    test "#{id} (#{mode}): seeded secret is reported; exact entry hides only it; broad entries hide nothing",
         ctx do
      class_case(ctx, @id, @mode)
    end
  end

  defp class_case(ctx, id, mode) do
    c = class(id)
    dir = tmp_dir!(ctx, "#{id}-#{mode}")
    tree = Path.join(dir, "tree")
    write!(tree, c.path, c.body.(c.secret))
    target = prepare(mode, tree)
    label = label(mode, c.path)
    d = digest(c.secret)
    locator = "#{c.pattern}:#{label}:#{d}"

    # Bare.
    r = scan(ctx, mode, target, allow(dir, []))
    assert r.status == 1, inspect(r)
    assert r.stderr == "#{label}:1:#{c.pattern}\nredaction-check: 1 finding(s)\n"
    assert r.stdout == locator <> "\n"

    # Exact entry: clean.
    r = scan(ctx, mode, target, allow(dir, [locator]))
    assert r.status == 0, inspect(r)
    assert r.stderr == ""
    assert r.stdout == locator <> "\nredaction-check: clean\n"

    # Same value at a new path: a new finding, and only that one.
    new_path = "archive/" <> c.path
    write!(tree, new_path, c.body.(c.secret))
    target = prepare(mode, tree)
    new_label = label(mode, new_path)

    r = scan(ctx, mode, target, allow(dir, [locator]))
    assert r.status == 1, inspect(r)
    assert r.stderr == "#{new_label}:1:#{c.pattern}\nredaction-check: 1 finding(s)\n"
    File.rm!(Path.join(tree, new_path))
    target = prepare(mode, tree)

    # Each broad spelling alone hides nothing.
    spellings = broad_spellings(c.pattern, label, d)
    assert length(spellings) == 7

    for entry <- spellings do
      assert broad_entry?(entry)
      r = scan(ctx, mode, target, allow(dir, [entry]))
      assert r.status == 1, "broad entry #{inspect(entry)} hid the finding: #{inspect(r)}"

      assert r.stderr == "#{label}:1:#{c.pattern}\nredaction-check: 1 finding(s)\n",
             "broad entry #{inspect(entry)}: #{inspect(r)}"
    end
  end

  # ---------------------------------------------------------------- across classes

  for mode <- [:paths, :git] do
    @mode mode

    test "all classes (#{mode}): one exact entry hides exactly its own finding", ctx do
      dir = tmp_dir!(ctx, "all-#{@mode}")
      tree = Path.join(dir, "tree")
      classes = Enum.map(@class_ids, &class/1)
      for c <- classes, do: write!(tree, c.path, c.body.(c.secret))
      target = prepare(@mode, tree)

      [first | rest] = classes
      first_locator = "#{first.pattern}:#{label(@mode, first.path)}:#{digest(first.secret)}"

      r = scan(ctx, @mode, target, allow(dir, [first_locator]))
      assert r.status == 1, inspect(r)

      expected =
        rest
        |> Enum.map(&"#{label(@mode, &1.path)}:1:#{&1.pattern}")
        |> Enum.sort()

      [summary | lines] = r.stderr |> String.split("\n", trim: true) |> Enum.reverse()
      assert summary == "redaction-check: 4 finding(s)"
      assert Enum.sort(lines) == expected
      refute Enum.any?(lines, &String.starts_with?(&1, label(@mode, first.path) <> ":"))
    end

    test "neutral baseline (#{mode}): every class with a placeholder is clean", ctx do
      dir = tmp_dir!(ctx, "baseline-#{@mode}")
      tree = Path.join(dir, "tree")
      for id <- @class_ids, c = class(id), do: write!(tree, c.path, c.body.("REDACTED"))
      target = prepare(@mode, tree)

      r = scan(ctx, @mode, target, allow(dir, []))
      assert r.status == 0, inspect(r)
      assert r.stdout == "redaction-check: clean\n"
      assert r.stderr == ""
    end
  end

  # ---------------------------------------------------------------- allowlist

  describe "the repository allowlist" do
    test "contains no broad entry" do
      entries =
        @repo_allowlist
        |> File.read!()
        |> String.split("\n")
        |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(String.trim(&1), "#")))
        |> Enum.map(fn line -> line |> String.split(" # ", parts: 2) |> hd() end)

      # Anti-vacuity: the file has reviewed exact entries today.
      assert length(entries) >= 10

      assert Enum.reject(entries, &broad_entry?/1) == entries,
             "broad: #{inspect(Enum.filter(entries, &broad_entry?/1))}"
    end

    test "the broad predicate accepts exact entries and rejects every spelling" do
      for id <- @class_ids do
        c = class(id)
        d = digest(c.secret)
        refute broad_entry?("#{c.pattern}:#{c.path}:#{d}")
        refute broad_entry?("#{c.pattern}:<external-1>/#{c.path}:#{d}")
        assert Enum.all?(broad_spellings(c.pattern, c.path, d), &broad_entry?/1)
      end
    end
  end

  # ---------------------------------------------------------------- harness

  defp tmp_dir!(_ctx, name) do
    dir = Path.join(System.tmp_dir!(), "ns30_m002_#{name}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write!(root, rel, content) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp allow(dir, entries) do
    path = Path.join(dir, "allow-#{System.unique_integer([:positive])}")
    File.write!(path, Enum.map_join(entries, "", &"#{&1} # ns30-m002 test entry\n"))
    path
  end

  # :paths scans the tree directly; :git makes the tree a repository whose files
  # are all tracked, re-staging on every call so added and removed files count.
  defp prepare(:paths, tree), do: tree

  defp prepare(:git, tree) do
    unless File.dir?(Path.join(tree, ".git")) do
      ok!(run(["git", "init", "-q"], tree))
    end

    ok!(run(["git", "add", "-A", "."], tree))

    ok!(
      run(
        [
          "git",
          "-c",
          "user.name=t",
          "-c",
          "user.email=t@example.invalid",
          "commit",
          "-q",
          "--allow-empty",
          "-m",
          "fixture"
        ],
        tree
      )
    )

    tree
  end

  defp label(:paths, rel), do: "<external-1>/" <> rel
  defp label(:git, rel), do: rel

  defp scan(_ctx, :paths, tree, allowlist),
    do: run(["bash", @scanner, "--allowlist", allowlist, "--locators", "--paths", tree], tree)

  defp scan(_ctx, :git, repo, allowlist),
    do: run(["bash", @scanner, "--allowlist", allowlist, "--locators"], repo)

  defp ok!(%{status: 0} = r), do: r
  defp ok!(r), do: flunk("child failed: #{inspect(r)}")

  # Bounded child: coreutils timeout, stdout captured, stderr to a per-call file.
  defp run([exe | args], cd) do
    timeout = System.find_executable("timeout") || flunk("coreutils timeout is required")
    bash = System.find_executable("bash") || flunk("bash is required")
    exe_path = System.find_executable(exe) || flunk("#{exe} is required")

    err =
      Path.join(System.tmp_dir!(), "ns30_m002_stderr_#{System.unique_integer([:positive])}")

    try do
      {stdout, status} =
        System.cmd(
          timeout,
          ["--kill-after=5s", "60s", bash, "-c", ~s(exec "$@" 2>"$NS30_M002_STDERR"), "ns30"] ++
            [exe_path | args],
          cd: cd,
          env: [
            {"NS30_M002_STDERR", err},
            {"GIT_CONFIG_GLOBAL", "/dev/null"},
            {"GIT_CONFIG_NOSYSTEM", "1"},
            {"LC_ALL", "C"}
          ]
        )

      %{status: status, stdout: stdout, stderr: File.read!(err)}
    after
      File.rm(err)
    end
  end
end
