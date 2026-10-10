# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MultiTenancy.ConnectionTest do
  @moduledoc """
  A connection may only exist once its database is open and migrated, so most of this is refusal.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias AshSqlite.MultiTenancy.Connection
  alias AshSqlite.MultiTenancy.Database
  alias AshSqlite.MultiTenancy.Registry, as: TenantRegistry

  @repo AshSqlite.TestRepo

  setup context do
    start_supervised!(TenantRegistry.child_spec(@repo))

    dir = Path.join(System.tmp_dir!(), "ash_sqlite_tenancy_#{:erlang.phash2(context.test)}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  describe "starting" do
    test "opens the tenant's database and publishes the repo instance", %{dir: dir} do
      {:ok, connection} = start_connection(dir, "acme")

      assert {:ok, ^connection, repo_pid} = TenantRegistry.lookup(@repo, "acme")
      assert is_pid(repo_pid)

      # The pool connects lazily, so the file appears on first use rather than at
      # start. Anything that touches the database is enough.
      assert {:ok, _} = query(connection, "select 1")
      assert File.exists?(Database.path(dir, "acme"))
    end

    test "a tenant whose name is not a filename still gets its own file", %{dir: dir} do
      {:ok, colon} = start_connection(dir, "acme:2026-08")
      {:ok, underscore} = start_connection(dir, "acme_2026-08")

      query!(colon, "create table only_in_colon (id integer)")
      query!(underscore, "select 1")

      assert File.exists?(Path.join(dir, "acme~3a2026-08.db"))
      assert File.exists?(Path.join(dir, "acme_2026-08.db"))

      # The point of the encoding: these are two databases, not one shared by two
      # tenants whose names sanitise to the same thing.
      assert {:error, _} = query(underscore, "select * from only_in_colon")
    end

    test "refuses a second connection for the same tenant", %{dir: dir} do
      {:ok, first} = start_connection(dir, "acme")

      assert {:error, {:already_started, ^first}} = start_connection(dir, "acme")
    end

    test "info/1 reports what is being served", %{dir: dir} do
      {:ok, connection} = start_connection(dir, "acme")

      info = Connection.info(connection)

      assert info.tenant == "acme"
      assert info.path == Database.path(dir, "acme")
      assert is_integer(info.opened_at)
    end
  end

  describe "migrations" do
    test "run before the tenant is available", %{dir: dir} do
      migrations = migrations_dir(dir, [{20_260_101_000_000, "create_widgets", :create_widgets}])

      {:ok, connection} = start_connection(dir, "acme", migrations_path: migrations)

      assert Connection.info(connection).schema_version == 20_260_101_000_000
      assert {:ok, %{rows: [[0]]}} = query(connection, "select count(*) from widgets")
    end

    test "are not re-run for a tenant that is already up to date", %{dir: dir} do
      migrations = migrations_dir(dir, [{20_260_101_000_000, "create_widgets", :create_widgets}])

      {:ok, connection} = start_connection(dir, "acme", migrations_path: migrations)
      query!(connection, "insert into widgets (name) values ('kept')")
      stop_connection(connection)

      {:ok, connection} = start_connection(dir, "acme", migrations_path: migrations)

      # A re-run would have raised on the existing table, and a fresh database
      # would have lost the row.
      assert {:ok, %{rows: [["kept"]]}} = query(connection, "select name from widgets")
      assert Connection.info(connection).schema_version == 20_260_101_000_000
    end

    test "a tenant behind the others catches up on activation", %{dir: dir} do
      first = migrations_dir(dir, [{20_260_101_000_000, "create_widgets", :create_widgets}])

      {:ok, connection} = start_connection(dir, "acme", migrations_path: first)
      stop_connection(connection)

      both =
        migrations_dir(dir, [
          {20_260_101_000_000, "create_widgets", :create_widgets},
          {20_260_202_000_000, "add_colour", :add_colour}
        ])

      {:ok, connection} = start_connection(dir, "acme", migrations_path: both)

      assert Connection.info(connection).schema_version == 20_260_202_000_000
      assert {:ok, _} = query(connection, "select colour from widgets")
    end

    test "a migrations path that is not a directory is a configuration error", %{dir: dir} do
      Process.flag(:trap_exit, true)
      missing = Path.join(dir, "nope")

      assert {:error, {:missing_migrations_path, ^missing}} =
               start_connection(dir, "acme", migrations_path: missing)

      # Distinct from a migration that failed: this one is true of every tenant on
      # the node, and quarantining one tenant over it would hide that.
      assert :error = TenantRegistry.lookup(@repo, "acme")
      refute File.exists?(Database.path(dir, "acme"))
    end

    test "a migration that raises stops the connection rather than serving", %{dir: dir} do
      Process.flag(:trap_exit, true)
      migrations = migrations_dir(dir, [{20_260_101_000_000, "explode", :raise}])

      assert {:error, {:migration_failed, _}} =
               start_connection(dir, "acme", migrations_path: migrations)

      assert :error = TenantRegistry.lookup(@repo, "acme")
    end

    test "no migrations path means no migration, not a failure", %{dir: dir} do
      {:ok, connection} = start_connection(dir, "acme")

      refute Connection.info(connection).schema_version
    end
  end

  describe "encryption" do
    test "refuses to open a plaintext database when a key was expected", %{dir: dir} do
      Process.flag(:trap_exit, true)

      assert {:error, :no_key} = start_connection(dir, "acme", encrypted?: true, key: nil)
      refute File.exists?(Database.path(dir, "acme"))
    end

    test "an unencrypted fleet opens without a key", %{dir: dir} do
      assert {:ok, _} = start_connection(dir, "acme", encrypted?: false, key: nil)
    end
  end

  describe "lifetime" do
    test "the connection stops when its repo instance dies", %{dir: dir} do
      Process.flag(:trap_exit, true)
      {:ok, connection} = start_connection(dir, "acme")
      {:ok, ^connection, repo_pid} = TenantRegistry.lookup(@repo, "acme")

      ref = Process.monitor(connection)
      Process.exit(repo_pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^connection, {:repo_exited, _}}, 2_000
      assert :error = TenantRegistry.lookup(@repo, "acme")
    end

    test "stop_repo/1 closes the database but keeps the process", %{dir: dir} do
      {:ok, connection} = start_connection(dir, "acme")
      {:ok, ^connection, repo_pid} = TenantRegistry.lookup(@repo, "acme")

      assert :ok = Connection.stop_repo(connection)

      refute Process.alive?(repo_pid)
      assert Process.alive?(connection)
      assert Connection.repo_pid(connection) == nil
    end

    test "stop_repo/1 twice is harmless", %{dir: dir} do
      {:ok, connection} = start_connection(dir, "acme")

      assert :ok = Connection.stop_repo(connection)
      assert :ok = Connection.stop_repo(connection)
    end

    test "stopping the connection closes the repo instance", %{dir: dir} do
      {:ok, connection} = start_connection(dir, "acme")
      {:ok, ^connection, repo_pid} = TenantRegistry.lookup(@repo, "acme")

      stop_connection(connection)

      refute Process.alive?(repo_pid)
      assert :error = TenantRegistry.lookup(@repo, "acme")
    end
  end

  # `AshSqlite.TestRepo` is configured with the sandbox pool, and a tenant instance
  # inherits the repo module's application config.
  defp start_connection(dir, tenant, opts \\ []) do
    Connection.start_link(
      Keyword.merge(
        [
          repo: @repo,
          tenant: tenant,
          path: Database.path(dir, tenant),
          repo_opts: [pool: DBConnection.ConnectionPool]
        ],
        opts
      )
    )
  end

  defp stop_connection(connection) do
    ref = Process.monitor(connection)
    GenServer.stop(connection)
    assert_receive {:DOWN, ^ref, :process, ^connection, _}, 2_000
  end

  defp query(connection, sql) do
    repo_pid = Connection.repo_pid(connection)
    previous = @repo.put_dynamic_repo(repo_pid)

    try do
      # `@repo.query/1`, not `Ecto.Adapters.SQL.query(@repo, ...)`: the latter looks up
      # the module's adapter meta and ignores the dynamic binding.
      @repo.query(sql)
    after
      @repo.put_dynamic_repo(previous)
    end
  end

  defp query!(connection, sql) do
    {:ok, result} = query(connection, sql)
    result
  end

  defp migrations_dir(dir, migrations) do
    path = Path.join(dir, "migrations")
    File.mkdir_p!(path)

    for {version, name, behaviour} <- migrations do
      # A unique module per written file, so that rewriting a directory to add a
      # later migration does not redefine the earlier one's module.
      module =
        Module.concat([
          Migrations,
          :"M#{:erlang.phash2(dir)}",
          :"V#{version}_#{System.unique_integer([:positive])}"
        ])

      File.write!(Path.join(path, "#{version}_#{name}.exs"), migration_source(module, behaviour))
    end

    path
  end

  defp migration_source(module, :raise) do
    """
    defmodule #{inspect(module)} do
      use Ecto.Migration

      def up, do: raise "no"
      def down, do: :ok
    end
    """
  end

  defp migration_source(module, :create_widgets) do
    """
    defmodule #{inspect(module)} do
      use Ecto.Migration

      def change do
        create table(:widgets, primary_key: false) do
          add :name, :text
        end
      end
    end
    """
  end

  defp migration_source(module, :add_colour) do
    """
    defmodule #{inspect(module)} do
      use Ecto.Migration

      def change do
        alter table(:widgets) do
          add :colour, :text
        end
      end
    end
    """
  end
end
