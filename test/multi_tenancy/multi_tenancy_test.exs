# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MultiTenancyTest do
  @moduledoc """
  The runtime end to end, against real database files.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias AshSqlite.MultiTenancy
  alias AshSqlite.MultiTenancy.Database

  @repo AshSqlite.TestRepo

  setup context do
    dir = Path.join(System.tmp_dir!(), "ash_sqlite_tenancy_#{:erlang.phash2(context.test)}")
    File.rm_rf!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  describe "connection_for/2" do
    test "activates a tenant that is not resident", %{dir: dir} do
      start_tenancy(dir)

      assert {:ok, repo_pid} = MultiTenancy.connection_for(@repo, "acme")
      assert is_pid(repo_pid)
      assert MultiTenancy.resident(@repo) == ["acme"]
    end

    test "returns the same connection for a resident tenant", %{dir: dir} do
      start_tenancy(dir)

      assert {:ok, first} = MultiTenancy.connection_for(@repo, "acme")
      assert {:ok, ^first} = MultiTenancy.connection_for(@repo, "acme")
    end

    test "gives each tenant its own connection", %{dir: dir} do
      start_tenancy(dir)

      {:ok, acme} = MultiTenancy.connection_for(@repo, "acme")
      {:ok, globex} = MultiTenancy.connection_for(@repo, "globex")

      refute acme == globex
    end
  end

  describe "isolation" do
    test "a row written for one tenant is not visible to another", %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))

      MultiTenancy.with_tenant(@repo, "acme", fn ->
        @repo.query!("insert into widgets (name) values ('acme only')")
      end)

      names =
        MultiTenancy.with_tenant(@repo, "globex", fn ->
          @repo.query!("select name from widgets").rows
        end)

      assert names == []

      assert MultiTenancy.with_tenant(@repo, "acme", fn ->
               @repo.query!("select name from widgets").rows
             end) == [["acme only"]]
    end

    test "tenants whose names would sanitise alike get separate databases", %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))

      MultiTenancy.with_tenant(@repo, "acme:eu", fn ->
        @repo.query!("insert into widgets (name) values ('colon')")
      end)

      assert MultiTenancy.with_tenant(@repo, "acme_eu", fn ->
               @repo.query!("select name from widgets").rows
             end) == []
    end
  end

  describe "with_tenant/3" do
    test "restores the previous binding afterwards", %{dir: dir} do
      start_tenancy(dir)
      before = @repo.get_dynamic_repo()

      MultiTenancy.with_tenant(@repo, "acme", fn -> :ok end)

      assert @repo.get_dynamic_repo() == before
    end

    test "restores the previous binding when the function raises", %{dir: dir} do
      start_tenancy(dir)
      before = @repo.get_dynamic_repo()

      assert_raise RuntimeError, fn ->
        MultiTenancy.with_tenant(@repo, "acme", fn -> raise "boom" end)
      end

      assert @repo.get_dynamic_repo() == before
    end

    test "raises rather than running against whatever was bound", %{dir: dir} do
      start_tenancy(dir, key_for: fn _tenant -> nil end)

      assert_raise AshSqlite.MultiTenancy.UnavailableError, ~r/unavailable/, fn ->
        MultiTenancy.with_tenant(@repo, "acme", fn -> :never end)
      end
    end
  end

  describe "residency" do
    test "closes the least recently used tenant beyond max_resident", %{dir: dir} do
      start_tenancy(dir, max_resident: 2)

      {:ok, _} = MultiTenancy.connection_for(@repo, "first")
      {:ok, _} = MultiTenancy.connection_for(@repo, "second")
      {:ok, _} = MultiTenancy.connection_for(@repo, "third")

      assert Enum.sort(MultiTenancy.resident(@repo)) == ["second", "third"]
    end

    test "never closes a tenant with a statement in flight", %{dir: dir} do
      start_tenancy(dir, max_resident: 2)

      {:ok, _} = MultiTenancy.connection_for(@repo, "first")
      {:ok, _} = MultiTenancy.connection_for(@repo, "second")

      # "first" is the least recently used, and is held bound for the duration.
      holder = hold("first")

      {:ok, _} = MultiTenancy.connection_for(@repo, "third")

      assert "first" in MultiTenancy.resident(@repo)
      refute "second" in MultiTenancy.resident(@repo)

      release(holder)
    end

    test "exceeds the limit rather than refusing when every tenant is in use", %{dir: dir} do
      start_tenancy(dir, max_resident: 1)

      {:ok, _} = MultiTenancy.connection_for(@repo, "first")
      holder = hold("first")

      assert {:ok, _} = MultiTenancy.connection_for(@repo, "second")
      assert Enum.sort(MultiTenancy.resident(@repo)) == ["first", "second"]

      release(holder)
    end

    test "a closed tenant keeps its data and reopens on demand", %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))

      MultiTenancy.with_tenant(@repo, "acme", fn ->
        @repo.query!("insert into widgets (name) values ('durable')")
      end)

      :ok = MultiTenancy.close(@repo, "acme")
      assert MultiTenancy.resident(@repo) == []
      assert File.exists?(Database.path(dir, "acme"))

      assert MultiTenancy.with_tenant(@repo, "acme", fn ->
               @repo.query!("select name from widgets").rows
             end) == [["durable"]]
    end
  end

  describe "delete/2" do
    test "removes the database and its sidecars", %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))

      MultiTenancy.with_tenant(@repo, "acme", fn ->
        @repo.query!("insert into widgets (name) values ('gone')")
      end)

      assert {:ok, removed} = MultiTenancy.delete(@repo, "acme")

      assert Database.path(dir, "acme") in removed
      refute File.exists?(Database.path(dir, "acme"))
      refute File.exists?(Database.path(dir, "acme") <> "-wal")
    end
  end

  describe "rename/3" do
    test "carries the tenant's data to the new name", %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))
      write("acme", "carried")

      # The write is still in the WAL rather than the database file, so this fails
      # unless the sidecars move with it.
      assert File.exists?(Database.path(dir, "acme") <> "-wal")

      assert :ok = MultiTenancy.rename(@repo, "acme", "acme-renamed")

      assert read("acme-renamed") == [["carried"]]
      refute File.exists?(Database.path(dir, "acme"))
      assert File.exists?(Database.path(dir, "acme-renamed"))
    end

    test "closes a resident tenant before moving its file", %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))
      {:ok, _} = MultiTenancy.connection_for(@repo, "acme")

      assert :ok = MultiTenancy.rename(@repo, "acme", "acme-renamed")
      assert MultiTenancy.resident(@repo) == []
    end

    test "renames a tenant whose name is not a filename", %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))
      write("acme:eu", "colon")

      assert :ok = MultiTenancy.rename(@repo, "acme:eu", "acme:us")

      assert read("acme:us") == [["colon"]]
      assert MultiTenancy.all_tenants(@repo) == ["acme:us"]
    end

    test "refuses to overwrite a tenant that already has a database", %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))
      write("acme", "keep me")
      write("globex", "do not clobber")

      assert {:error, :target_exists} = MultiTenancy.rename(@repo, "acme", "globex")

      assert read("globex") == [["do not clobber"]]
      assert read("acme") == [["keep me"]]
    end

    test "refuses a tenant with no database, rather than reporting success", %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))

      assert {:error, :no_database} = MultiTenancy.rename(@repo, "never-seen", "renamed")
    end

    test "renaming a tenant to itself leaves it alone", %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))
      write("acme", "untouched")

      assert :ok = MultiTenancy.rename(@repo, "acme", "acme")
      assert read("acme") == [["untouched"]]
    end

    test "the new name serves reads and writes afterwards", %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))
      write("acme", "before")

      assert :ok = MultiTenancy.rename(@repo, "acme", "acme-renamed")
      write("acme-renamed", "after")

      assert read("acme-renamed") == [["after"], ["before"]]
    end
  end

  describe "quarantine" do
    test "a tenant that cannot open is refused without retrying", %{dir: dir} do
      start_tenancy(dir, key_for: fn _tenant -> nil end)

      assert {:error, :no_key} = MultiTenancy.connection_for(@repo, "acme")
      assert {:error, {:quarantined, :no_key}} = MultiTenancy.connection_for(@repo, "acme")
      assert MultiTenancy.quarantined(@repo) == %{"acme" => :no_key}
    end

    test "release/2 lets the next request try again", %{dir: dir} do
      start_tenancy(dir, key_for: fn _tenant -> nil end)

      {:error, :no_key} = MultiTenancy.connection_for(@repo, "acme")
      :ok = MultiTenancy.release(@repo, "acme")

      assert MultiTenancy.quarantined(@repo) == %{}
      # Still broken, so it fails the same way rather than being quarantined-stale.
      assert {:error, :no_key} = MultiTenancy.connection_for(@repo, "acme")
    end

    test "quarantines one tenant without affecting another", %{dir: dir} do
      start_tenancy(dir, key_for: fn tenant -> if tenant == "acme", do: nil, else: "unused" end)

      assert {:error, :no_key} = MultiTenancy.connection_for(@repo, "acme")
      assert Map.keys(MultiTenancy.quarantined(@repo)) == ["acme"]
    end
  end

  describe "seal/1" do
    test "refuses new tenants, and unseal/1 allows them again", %{dir: dir} do
      start_tenancy(dir)
      {:ok, resident} = MultiTenancy.connection_for(@repo, "acme")

      :ok = MultiTenancy.seal(@repo)

      assert {:error, :draining} = MultiTenancy.connection_for(@repo, "globex")
      # An already-resident tenant keeps serving, so work in flight can finish.
      assert {:ok, ^resident} = MultiTenancy.connection_for(@repo, "acme")

      :ok = MultiTenancy.unseal(@repo)
      assert {:ok, _} = MultiTenancy.connection_for(@repo, "globex")
    end
  end

  describe "all_tenants/1" do
    test "is empty for a fleet nobody has used yet", %{dir: dir} do
      start_tenancy(dir)

      assert MultiTenancy.all_tenants(@repo) == []
    end

    test "lists a tenant whether it is resident or only on disk", %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))
      {:ok, _} = MultiTenancy.connection_for(@repo, "acme")
      {:ok, _} = MultiTenancy.connection_for(@repo, "globex")
      :ok = MultiTenancy.close(@repo, "globex")

      assert MultiTenancy.resident(@repo) == ["acme"]
      assert Enum.sort(MultiTenancy.all_tenants(@repo)) == ["acme", "globex"]
    end

    test "lists a resident tenant that has not written its file yet", %{dir: dir} do
      start_tenancy(dir)
      {:ok, _} = MultiTenancy.connection_for(@repo, "acme")

      assert MultiTenancy.all_tenants(@repo) == ["acme"]
    end

    test "recovers from disk a tenant whose name is not a filename", %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))
      {:ok, _} = MultiTenancy.connection_for(@repo, "acme:eu/1")
      :ok = MultiTenancy.close(@repo, "acme:eu/1")

      assert MultiTenancy.all_tenants(@repo) == ["acme:eu/1"]
    end

    test "counts a tenant once, not once per file it owns", %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))

      MultiTenancy.with_tenant(@repo, "acme", fn ->
        @repo.query!("insert into widgets (name) values ('one')")
      end)

      assert Enum.any?(File.ls!(dir), &String.ends_with?(&1, "-wal"))
      assert MultiTenancy.all_tenants(@repo) == ["acme"]
    end

    test "ignores files no tenant could have produced", %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))
      {:ok, _} = MultiTenancy.connection_for(@repo, "acme")
      :ok = MultiTenancy.close(@repo, "acme")
      File.write!(Path.join(dir, "notes.txt"), "")
      File.write!(Path.join(dir, "Backup.db"), "")

      assert MultiTenancy.all_tenants(@repo) == ["acme"]
    end
  end

  describe "migrate_all/3" do
    test "migrates each tenant and closes it again", %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))

      results = MultiTenancy.migrate_all(@repo, ["acme", "globex"])

      assert results == [
               {"acme", {:ok, 20_260_101_000_000}},
               {"globex", {:ok, 20_260_101_000_000}}
             ]

      assert MultiTenancy.resident(@repo) == []
      assert File.exists?(Database.path(dir, "acme"))
      assert File.exists?(Database.path(dir, "globex"))
    end

    test "migrates every tenant on disk when given none", %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))
      {:ok, _} = MultiTenancy.connection_for(@repo, "acme")
      {:ok, _} = MultiTenancy.connection_for(@repo, "globex")

      assert [{"acme", {:ok, _}}, {"globex", {:ok, _}}] =
               @repo |> MultiTenancy.migrate_all() |> Enum.sort()
    end

    test "reports the tenants that failed rather than stopping", %{dir: dir} do
      start_tenancy(dir, key_for: fn tenant -> if tenant == "acme", do: nil, else: "unused" end)

      assert [{"acme", {:error, :no_key}}, {"globex", _}] =
               MultiTenancy.migrate_all(@repo, ["acme", "globex"])
    end
  end

  describe "path_for/2" do
    test "names the file a tenant would use", %{dir: dir} do
      start_tenancy(dir)

      assert MultiTenancy.path_for(@repo, "acme:eu") == Path.join(dir, "acme~3aeu.db")
    end
  end

  describe "configuration" do
    test "a migrations_path that is not a directory fails at boot", %{dir: dir} do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
               MultiTenancy.start_link(
                 repo: @repo,
                 dir: dir,
                 migrations_path: Path.join(dir, "nope")
               )

      assert message =~ "is not a directory"
    end
  end

  defp write(tenant, name) do
    MultiTenancy.with_tenant(@repo, tenant, fn ->
      @repo.query!("insert into widgets (name) values ('#{name}')")
    end)
  end

  defp read(tenant) do
    MultiTenancy.with_tenant(@repo, tenant, fn ->
      @repo.query!("select name from widgets order by name").rows
    end)
  end

  defp start_tenancy(dir, opts \\ []) do
    opts =
      Keyword.merge(
        [
          repo: @repo,
          dir: dir,
          # A tenant instance inherits the repo module's config, which here names the
          # sandbox pool -- one connection shared between processes.
          repo_opts: [pool: DBConnection.ConnectionPool]
        ],
        opts
      )

    start_supervised!({MultiTenancy, opts})
  end

  defp migrations(dir) do
    path = Path.join(dir, "migrations")
    File.mkdir_p!(path)
    module = Module.concat([TenancyMigrations, :"M#{:erlang.phash2(dir)}"])

    File.write!(Path.join(path, "20260101000000_create_widgets.exs"), """
    defmodule #{inspect(module)} do
      use Ecto.Migration

      def change do
        create table(:widgets, primary_key: false) do
          add :name, :text
        end
      end
    end
    """)

    path
  end

  # Holds a tenant bound in another process until told to stop, so that eviction
  # has something genuinely in use to skip.
  # Holds a tenant bound in another process, so eviction has something in use to skip.
  defp hold(tenant) do
    test = self()

    spawn_link(fn ->
      MultiTenancy.with_tenant(@repo, tenant, fn ->
        send(test, {:holding, self()})
        receive do: (:release -> :ok)
      end)
    end)

    receive do
      {:holding, pid} -> pid
    after
      1_000 -> flunk("holder never bound #{tenant}")
    end
  end

  defp release(holder) do
    send(holder, :release)
  end
end
