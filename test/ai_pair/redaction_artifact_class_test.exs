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

  The five classes are the five Orris artifact categories: fixtures, evidence,
  prompts, logs and packages. They come from Orris `test/redaction_check_test.sh:183-189`
  at Orris main `24eee05a3a081923c2e7c5e2e4a61b95e6c09ec9`, as cited by the pair
  review. That file was not readable from the session that wrote this test (Orris
  is outside its repository scope), so the category list is taken from the review.
  Where Orrisd has an equivalent store, the class uses Orrisd's own path. Where it
  has none, the class uses the exact Orris path from that file, as reported by
  the review.

  Every class FILE is a synthetic fixture, written at run time into a temporary
  tree at the relative path below. No real store is read. The real Orrisd stores
  are OUT-OF-TREE under the daemon inbox (default `~/.ai-agent-inbox/ai-pair`, see
  `lib/ai_pair/inbox.ex`) and may hold operator data, so the scanner is never
  pointed at them. It sees these files exactly as it would see the real ones if
  they were passed with `--paths` or committed.

  | # | category | relative path | path is | seeded pattern |
  |---|----------|---------------|---------|----------------|
  | 1 | fixtures | `test/fixtures/fingerprints/codex_cli/seeded_capture.txt` | an Orrisd in-tree path shape, beside the real tracked fixtures in `test/fixtures/fingerprints/codex_cli/` | `github_token` |
  | 2 | evidence | `delivery/receipts.jsonl` | a real Orrisd store path, the delivery receipt log (`lib/ai_pair/delivery/receipt_log.ex:12-13`), out-of-tree | `aws_access_key` |
  | 3 | prompts | `inbox/msg-0001.json` | a real Orrisd store path, a delivered-prompt envelope in `$AI_PAIR_INBOX/inbox/` (`lib/ai_pair/inbox/stuck_scanner.ex:64,72`), out-of-tree | `slack_token` |
  | 4 | logs | `logs/run.log` | the exact Orris shape (Orris `test/redaction_check_test.sh:183-189`). Orrisd writes no log file (`Logger` goes to the console), so there is no Orrisd equivalent | `anthropic_token` |
  | 5 | packages | `packages/manifest.json` | the exact Orris shape (same lines). Orrisd keeps no package store (its release is built by Nix), so there is no Orrisd equivalent | `gitlab_token` |

  Two Orrisd stores fit none of the five categories. They are named here and not
  seeded: the pane-intent store `state/pane-attachments.json`
  (`lib/ai_pair/pane_intent_store.ex:73-74`) and the boot report
  `state/boot-report.json` (`lib/ai_pair/pane_restore/boot.ex:191`).

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
  Every child gets an isolated environment:

    * every `GIT_*` variable inherited from the caller is unset, including
      `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY`,
      `GIT_ALTERNATE_OBJECT_DIRECTORIES`, `GIT_COMMON_DIR`, `GIT_NAMESPACE`,
      `GIT_CEILING_DIRECTORIES` and `GIT_CONFIG*`. These are also unset
      explicitly, so no inherited variable can redirect the repository;
    * `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1` are set;
    * `HOME` and `XDG_CONFIG_HOME` point at an empty directory inside the test's
      temporary tree, so no operator configuration or global excludes file is
      read and none can hide a fixture.

  Before every scan the test asserts two things. First, the regular files in the
  tree are exactly the expected class paths. Second, in git mode,
  `git ls-files -z` in the temporary repository lists exactly those paths. So
  each scan provably covers what it claims to. Every temporary tree and
  repository is uniquely named and removed in `on_exit`, which also runs when a
  test fails.

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

  @class_ids [:fixtures, :evidence, :prompts, :logs, :packages]

  # ---------------------------------------------------------------- classes

  # Secrets are assembled from fragments so this file holds no scannable value.
  defp class(:fixtures) do
    secret = "g" <> "hp_" <> String.duplicate("Ns30M002Fx", 4)

    %{
      path: "test/fixtures/fingerprints/codex_cli/seeded_capture.txt",
      pattern: "github_token",
      body: fn value -> "> export TOKEN=#{value} && run the tool\n" end,
      secret: secret
    }
  end

  defp class(:evidence) do
    secret = "A" <> "KIA" <> "NS30M002EVIDENCE"

    %{
      path: "delivery/receipts.jsonl",
      pattern: "aws_access_key",
      body: fn value ->
        ~s({"schema":"ai_pair.receipt","seq":1,"status":"delivered","note":"#{value}"}\n)
      end,
      secret: secret
    }
  end

  defp class(:prompts) do
    secret = "x" <> "oxb-" <> "ns30-m002-prompt-envelope"

    %{
      path: "inbox/msg-0001.json",
      pattern: "slack_token",
      body: fn value -> ~s({"msg_id":"msg-0001","role":"peer","body":"use #{value}"}\n) end,
      secret: secret
    }
  end

  defp class(:logs) do
    secret = "s" <> "k-ant-" <> "ns30_m002_orrisd_log_line00"

    %{
      path: "logs/run.log",
      pattern: "anthropic_token",
      body: fn value -> "12:00:00.000 [info] request header x-api-key=#{value}\n" end,
      secret: secret
    }
  end

  defp class(:packages) do
    secret = "g" <> "lpat-" <> "ns30_m002_package_json00"

    %{
      path: "packages/manifest.json",
      pattern: "gitlab_token",
      body: fn value -> ~s({"name":"example","publishConfig":{"token":"#{value}"}}\n) end,
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
    target = prepare(mode, tree, [c.path])
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
    target = prepare(mode, tree, [c.path, new_path])
    new_label = label(mode, new_path)

    r = scan(ctx, mode, target, allow(dir, [locator]))
    assert r.status == 1, inspect(r)
    assert r.stderr == "#{new_label}:1:#{c.pattern}\nredaction-check: 1 finding(s)\n"
    File.rm!(Path.join(tree, new_path))
    target = prepare(mode, tree, [c.path])

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
      target = prepare(@mode, tree, Enum.map(classes, & &1.path))

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
      target = prepare(@mode, tree, Enum.map(@class_ids, &class(&1).path))

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

      # Anti-vacuity: 38 reviewed exact entries at 4a02ff50; a floor, not an exact count.
      assert length(entries) >= 38

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
  # Either way the tree must hold exactly `expected`, and in git mode the index
  # must list exactly `expected`, before any scan is trusted.
  defp prepare(mode, tree, expected) do
    expected = Enum.sort(expected)
    assert tree_files(tree) == expected
    target = prepare(mode, tree)

    if mode == :git do
      r = ok!(run(["git", "ls-files", "-z"], tree))
      assert r.stdout |> String.split(<<0>>, trim: true) |> Enum.sort() == expected
    end

    target
  end

  defp tree_files(tree) do
    tree
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, tree))
    |> Enum.reject(&String.starts_with?(&1, ".git/"))
    |> Enum.sort()
  end

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

  @git_redirects ~w(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
                    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE
                    GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG
                    GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_EXEC_PATH GIT_TEMPLATE_DIR)

  # Every inherited GIT_* is unset, the known redirects explicitly so, and HOME /
  # XDG_CONFIG_HOME point at an empty directory: no operator config or excludes.
  defp child_env(err, home) do
    inherited = for {k, _} <- System.get_env(), String.starts_with?(k, "GIT_"), do: {k, nil}

    inherited ++
      Enum.map(@git_redirects, &{&1, nil}) ++
      [
        {"NS30_M002_STDERR", err},
        {"GIT_CONFIG_GLOBAL", "/dev/null"},
        {"GIT_CONFIG_NOSYSTEM", "1"},
        {"HOME", home},
        {"XDG_CONFIG_HOME", home},
        {"LC_ALL", "C"}
      ]
  end

  # Bounded child: coreutils timeout, stdout captured, stderr to a per-call file.
  defp run([exe | args], cd) do
    timeout = System.find_executable("timeout") || flunk("coreutils timeout is required")
    bash = System.find_executable("bash") || flunk("bash is required")
    exe_path = System.find_executable(exe) || flunk("#{exe} is required")

    err =
      Path.join(System.tmp_dir!(), "ns30_m002_stderr_#{System.unique_integer([:positive])}")

    # An empty HOME beside the tree, inside the test's own temporary directory.
    home = Path.join(Path.dirname(cd), "home")
    File.mkdir_p!(home)

    try do
      {stdout, status} =
        System.cmd(
          timeout,
          ["--kill-after=5s", "60s", bash, "-c", ~s(exec "$@" 2>"$NS30_M002_STDERR"), "ns30"] ++
            [exe_path | args],
          cd: cd,
          env: child_env(err, home)
        )

      %{status: status, stdout: stdout, stderr: File.read!(err)}
    after
      File.rm(err)
    end
  end
end
