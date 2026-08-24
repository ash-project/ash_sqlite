# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MultiTenancy.ManagedTest do
  @moduledoc """
  A `strategy :context` resource with nothing configured but `AshSqlite.MultiTenancy`,
  driven through Ash and checked against the files on disk.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias AshSqlite.ManagedTenantRepo
  alias AshSqlite.MultiTenancy
  alias AshSqlite.Test.ManagedPost

  require Ash.Query

  setup context do
    dir = Path.join(System.tmp_dir!(), "ash_sqlite_managed_#{:erlang.phash2(context.test)}")
    File.rm_rf!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    start_supervised!(
      {MultiTenancy,
       repo: ManagedTenantRepo,
       dir: dir,
       migrations_path: migrations(dir),
       repo_opts: [pool: DBConnection.ConnectionPool]}
    )

    {:ok, dir: dir}
  end

  describe "wiring" do
    test "a context-multitenant resource with no binder gets the default" do
      assert AshSqlite.DataLayer.Info.tenant_binder(ManagedPost) == AshSqlite.MultiTenancy.Binder
    end

    test "a resource that names a binder keeps it" do
      assert AshSqlite.DataLayer.Info.tenant_binder(AshSqlite.Test.TenantedPost) ==
               AshSqlite.Test.TenantBinder
    end

    test "a resource with no context multitenancy has no binder" do
      refute AshSqlite.DataLayer.Info.tenant_binder(AshSqlite.Test.Post)
    end
  end

  describe "reads and writes" do
    test "a create lands in its own tenant's file", %{dir: dir} do
      create!("acme", "acme one")
      create!("acme", "acme two")
      create!("globex", "globex one")

      assert titles_in_file(dir, "acme") == ["acme one", "acme two"]
      assert titles_in_file(dir, "globex") == ["globex one"]
    end

    test "a read only sees its own tenant" do
      create!("acme", "acme one")
      create!("globex", "globex one")

      assert titles("acme") == ["acme one"]
      assert titles("globex") == ["globex one"]
    end

    test "an update stays in its own tenant", %{dir: dir} do
      post = create!("acme", "before")
      create!("globex", "untouched")

      post |> Ash.Changeset.for_update(:update, %{title: "after"}) |> Ash.update!(tenant: "acme")

      assert titles_in_file(dir, "acme") == ["after"]
      assert titles_in_file(dir, "globex") == ["untouched"]
    end

    test "a destroy stays in its own tenant", %{dir: dir} do
      post = create!("acme", "doomed")
      create!("globex", "safe")

      Ash.destroy!(post, tenant: "acme")

      assert titles_in_file(dir, "acme") == []
      assert titles_in_file(dir, "globex") == ["safe"]
    end
  end

  describe "the paths a caller could not have wrapped" do
    test "Ash.count/2 goes through the binder with the right tenant" do
      create!("acme", "one")
      create!("globex", "one")
      create!("globex", "two")

      assert Ash.count!(ManagedPost, tenant: "acme") == 1
      assert Ash.count!(ManagedPost, tenant: "globex") == 2
    end

    test "an atomic bulk update stays in its own tenant", %{dir: dir} do
      create!("acme", "before")
      create!("globex", "before")

      ManagedPost
      |> Ash.Query.filter(title == "before")
      |> Ash.bulk_update!(:update, %{title: "after"}, tenant: "acme", strategy: :atomic)

      assert titles_in_file(dir, "acme") == ["after"]
      assert titles_in_file(dir, "globex") == ["before"]
    end
  end

  describe "tenants" do
    test "each tenant is a separate file, named as MultiTenancy says", %{dir: dir} do
      create!("acme", "one")

      assert File.exists?(MultiTenancy.path_for(ManagedTenantRepo, "acme"))
      assert MultiTenancy.path_for(ManagedTenantRepo, "acme") == Path.join(dir, "acme.db")
    end

    test "a tenant met for the first time is migrated on activation", %{dir: dir} do
      create!("acme", "one")

      # "globex" has never been seen, so its database does not exist yet and its
      # table can only come from the migration running at activation.
      refute File.exists?(Path.join(dir, "globex.db"))
      assert create!("globex", "one").title == "one"
      assert titles_in_file(dir, "globex") == ["one"]
    end

    test "a tenant reopened after being closed keeps its rows" do
      create!("acme", "durable")
      :ok = MultiTenancy.close(ManagedTenantRepo, "acme")

      assert MultiTenancy.resident(ManagedTenantRepo) == []
      assert titles("acme") == ["durable"]
    end

    test "tenants whose names would sanitise alike stay separate", %{dir: dir} do
      create!("acme:eu", "colon")

      assert titles("acme_eu") == []
      assert titles_in_file(dir, "acme:eu") == ["colon"]
    end
  end

  describe "refusals" do
    test "Ash refuses a tenantless query before the data layer sees it" do
      assert_raise Ash.Error.Invalid, ~r/require a tenant to be specified/, fn ->
        Ash.read!(ManagedPost)
      end
    end

    test "the data layer refuses one on the paths that bypass an action" do
      assert_raise ArgumentError, ~r/carried no tenant/, fn ->
        AshSqlite.DataLayer.transaction(ManagedPost, fn -> :unreachable end)
      end
    end
  end

  describe "transactions" do
    test "a failed action rolls its write back", %{dir: dir} do
      assert_raise RuntimeError, fn ->
        AshSqlite.DataLayer.transaction(
          ManagedPost,
          fn ->
            create!("acme", "rolled back")
            raise "no"
          end,
          nil,
          %{type: :custom, metadata: %{}, data_layer_context: %{tenant: "acme"}}
        )
      end

      assert titles_in_file(dir, "acme") == []
    end

    test "a transaction refuses to reach into another tenant's database" do
      assert_raise Ash.Error.Unknown, ~r/open on another tenant's database/, fn ->
        AshSqlite.DataLayer.transaction(
          ManagedPost,
          fn -> create!("globex", "wrong database") end,
          nil,
          %{type: :custom, metadata: %{}, data_layer_context: %{tenant: "acme"}}
        )
      end
    end
  end

  defp create!(tenant, title) do
    ManagedPost
    |> Ash.Changeset.for_create(:create, %{title: title})
    |> Ash.create!(tenant: tenant)
  end

  defp titles(tenant) do
    ManagedPost |> Ash.read!(tenant: tenant) |> Enum.map(& &1.title) |> Enum.sort()
  end

  # Read with Exqlite rather than through Ash, so isolation is checked against the
  # bytes on disk and not against the thing under test.
  defp titles_in_file(dir, tenant) do
    path = Path.join(dir, AshSqlite.MultiTenancy.Database.encode(tenant) <> ".db")
    {:ok, db} = Exqlite.Sqlite3.open(path)
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "SELECT title FROM managed_posts ORDER BY title")
    {:ok, rows} = Exqlite.Sqlite3.fetch_all(db, stmt)
    :ok = Exqlite.Sqlite3.close(db)
    List.flatten(rows)
  end

  defp migrations(dir) do
    path = Path.join(dir, "migrations")
    File.mkdir_p!(path)
    module = Module.concat([ManagedMigrations, :"M#{:erlang.phash2(dir)}"])

    File.write!(Path.join(path, "20260101000000_create_managed_posts.exs"), """
    defmodule #{inspect(module)} do
      use Ecto.Migration

      def change do
        create table(:managed_posts, primary_key: false) do
          add :id, :text, primary_key: true
          add :title, :text
        end
      end
    end
    """)

    path
  end
end
