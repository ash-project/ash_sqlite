# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MultiTenancyTest do
  @moduledoc """
  Tenants opened by `AshSqlite.MultiTenancy`, checked against the files on disk.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias AshSqlite.Test.{MultiTenancyPost, MultiTenancyRepo}

  @migrations Path.expand("migrations", __DIR__)

  defmodule NoCallbackRepo do
    @moduledoc false
    use AshSqlite.Repo, otp_app: :ash_sqlite

    def min_sqlite_version, do: %Version{major: 3, minor: 38, patch: 0}
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "ash_sqlite_mt_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp start_repo(dir, tenants \\ []) do
    start_supervised!(
      {MultiTenancyRepo,
       tenants: Keyword.merge([dir: dir, migrations_path: @migrations], tenants)}
    )
  end

  defp create!(tenant, title) do
    MultiTenancyPost
    |> Ash.Changeset.for_create(:create, %{title: title}, tenant: tenant)
    |> Ash.create!()
  end

  defp titles(tenant) do
    MultiTenancyPost |> Ash.read!(tenant: tenant) |> Enum.map(& &1.title) |> Enum.sort()
  end

  defp titles_in_file(path) do
    {:ok, db} = Exqlite.Sqlite3.open(path)
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "SELECT title FROM posts ORDER BY title")
    {:ok, rows} = Exqlite.Sqlite3.fetch_all(db, stmt)
    :ok = Exqlite.Sqlite3.close(db)
    List.flatten(rows)
  end

  defp db_files(dir),
    do:
      dir
      |> File.ls!()
      |> Enum.map(&Path.join(dir, &1))
      |> Enum.filter(&String.ends_with?(&1, ".db"))

  test "a repo without tenants: gets Ecto's child spec" do
    assert AshSqlite.TestRepo.child_spec([]) == %{
             id: AshSqlite.TestRepo,
             start: {AshSqlite.TestRepo, :start_link, [[]]},
             type: :supervisor
           }
  end

  test "tenants: without tenant_repo/2 raises at boot", %{dir: dir} do
    assert_raise ArgumentError,
                 ~r/`tenants:`.*\n.*AshSqlite.MultiTenancy.tenant_repo\(__MODULE__/s,
                 fn ->
                   NoCallbackRepo.child_spec(tenants: [dir: dir])
                 end
  end

  test "using the helper with no tenants: config raises a named error" do
    assert_raise Ash.Error.Unknown, ~r/no tenant supervisor running.*config :my_app/s, fn ->
      create!("acme", "one")
    end
  end

  test "an Ash create and read go to each tenant's own file", %{dir: dir} do
    start_repo(dir)

    create!("acme", "a1")
    create!("globex", "g1")

    assert titles("acme") == ["a1"]
    assert titles("globex") == ["g1"]
    assert titles_in_file(Path.join(dir, "acme.db")) == ["a1"]
    assert titles_in_file(Path.join(dir, "globex.db")) == ["g1"]
  end

  test "tenants that sanitising would merge get different files", %{dir: dir} do
    start_repo(dir)

    create!("a:b", "colon")
    create!("a_b", "underscore")
    create!("../../etc/x", "traversal")

    files = db_files(dir)
    assert length(files) == 3
    assert Enum.all?(files, &(Path.dirname(&1) == dir))
    assert titles("a:b") == ["colon"]
    assert titles("a_b") == ["underscore"]
  end

  test "concurrent first use of a cold tenant starts one process and one instance", %{dir: dir} do
    start_repo(dir)

    instances =
      1..20
      |> Enum.map(fn _ ->
        Task.async(fn -> MultiTenancyRepo.tenant_repo("cold", %{}) end)
      end)
      |> Task.await_many()

    assert [_] = Enum.uniq(instances)
    assert [{_, _}] = Registry.lookup(MultiTenancyRepo.TenantRegistry, "cold")
    assert %{active: 1} = DynamicSupervisor.count_children(MultiTenancyRepo.Tenants)
  end

  test "a migration that raises fails the open", %{dir: dir} do
    migrations = Path.join(dir, "migrations")
    File.mkdir_p!(migrations)

    File.write!(Path.join(migrations, "20260101000000_boom.exs"), """
    defmodule AshSqlite.Test.MultiTenancyMigrations.Boom do
      use Ecto.Migration
      def up, do: raise("boom")
    end
    """)

    start_repo(Path.join(dir, "tenants"), migrations_path: migrations)

    assert_raise RuntimeError, ~r/could not open the database of tenant "acme".*boom/s, fn ->
      MultiTenancyRepo.tenant_repo("acme", %{})
    end
  end

  test "killing the repo supervisor takes tenants and instances with it", %{dir: dir} do
    supervisor = start_repo(dir)
    instance = MultiTenancyRepo.tenant_repo("acme", %{})
    [{tenant, _}] = Registry.lookup(MultiTenancyRepo.TenantRegistry, "acme")

    refs = Enum.map([supervisor, tenant, instance], &Process.monitor/1)
    Process.exit(supervisor, :kill)

    for ref <- refs, do: assert_receive({:DOWN, ^ref, _, _, _})
  end
end
