defmodule AiPair.Contracts.DependencyInventoryTest do
  @moduledoc """
  Binds `DEPENDENCIES.org` to the dependency set the build actually resolves.

  The inventory is the provenance half of the release obligation: it names every
  package the source pulls in, its version, whether it is a direct or transitive
  dependency, and its license. It was prose. Nothing stopped a dependency being
  added, removed or bumped in `mix.exs` and `mix.lock` while the table kept
  describing the previous build, and a provenance record that can silently go
  stale is not evidence.

  What is measured here is the lockfile and the declared dependency list, which
  is what the gate can see: every locked package appears in the table exactly
  once, at the locked version, with the role the project file implies, and the
  table names nothing the lock does not contain.

  What is NOT measured, stated so the coverage is not overread: the license
  column. Licenses come from inspecting upstream archives, which no in-gate
  measurement reproduces, so they remain prose that a human checked. The test
  asserts only that every row carries one.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @inventory_path Path.join(@root, "DEPENDENCIES.org")
  @lock_path Path.join(@root, "mix.lock")

  @hex_prefix "https://hex.pm/packages/"

  setup_all do
    # mix.lock spells its keys as quoted keywords, which the tokenizer warns
    # about once per package. Those warnings belong to the lockfile format, not
    # to anything this test found, so they are collected rather than printed
    # into every gate run.
    {{lock, _bindings}, _diagnostics} =
      Code.with_diagnostics(fn -> Code.eval_file(@lock_path) end)

    locked =
      Map.new(lock, fn {app, entry} when is_tuple(entry) ->
        {app, %{package: entry |> elem(1) |> Atom.to_string(), version: elem(entry, 2)}}
      end)

    {:ok, locked: locked, rows: inventory_rows()}
  end

  test "every locked package appears in the inventory once, at the locked version", %{
    locked: locked,
    rows: rows
  } do
    by_package = Map.new(rows, fn row -> {row.package, row} end)

    assert map_size(by_package) == length(rows),
           "DEPENDENCIES.org lists a package more than once"

    for {app, %{package: package, version: version}} <- locked do
      row = by_package[package]

      assert row,
             "mix.lock pins #{package} (app #{app}) and DEPENDENCIES.org does not list it"

      assert row.version == version,
             "DEPENDENCIES.org records #{package} #{row.version} but mix.lock pins #{version}"

      assert row.link_version == version,
             "the #{package} row links version #{row.link_version} but records #{version}"
    end
  end

  test "the inventory lists nothing the lockfile does not contain", %{locked: locked, rows: rows} do
    locked_packages = locked |> Map.values() |> Enum.map(& &1.package) |> MapSet.new()
    listed = rows |> Enum.map(& &1.package) |> MapSet.new()

    assert MapSet.subset?(listed, locked_packages),
           "DEPENDENCIES.org lists packages mix.lock does not pin: " <>
             inspect(MapSet.to_list(MapSet.difference(listed, locked_packages)))
  end

  test "each package carries the role the project file implies", %{locked: locked, rows: rows} do
    direct =
      Mix.Project.config()[:deps]
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    by_package = Map.new(rows, fn row -> {row.package, row} end)

    for {app, %{package: package}} <- locked do
      expected =
        if MapSet.member?(direct, app), do: "Direct runtime", else: "Transitive"

      assert by_package[package].role == expected,
             "DEPENDENCIES.org calls #{package} #{inspect(by_package[package].role)} but " <>
               "mix.exs makes it #{expected}"
    end
  end

  test "every row carries a license", %{rows: rows} do
    for row <- rows do
      refute row.license == "",
             "DEPENDENCIES.org records no license for #{row.package}"
    end
  end

  defp inventory_rows do
    @inventory_path
    |> File.read!()
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "| [[" <> @hex_prefix))
    |> Enum.map(&parse_row/1)
  end

  defp parse_row(line) do
    [name_cell, version, role, license] =
      line
      |> String.trim()
      |> String.split("|", trim: true)
      |> Enum.map(&String.trim/1)

    [link, label] =
      name_cell
      |> String.trim_leading("[[")
      |> String.trim_trailing("]]")
      |> String.split("][")

    [link_package, link_version] =
      link
      |> String.trim_leading(@hex_prefix)
      |> String.split("/")

    assert label == link_package,
           "the #{link_package} row labels itself #{label}"

    %{
      package: link_package,
      link_version: link_version,
      version: version,
      role: role,
      license: license
    }
  end
end
