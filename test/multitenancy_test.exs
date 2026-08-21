# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MultitenancyTest do
  @moduledoc """
  Context multitenancy against two real database files.

  SQLite has no schemas, so `strategy :context` cannot be a query prefix — the
  generated SQL is identical for every tenant, and isolation comes entirely from
  which file the connection is attached to. These tests therefore run against two
  separate files and check isolation by reading each file directly, rather than by
  asking the thing under test whether it worked.
  """
  use ExUnit.Case, async: false

  alias AshSqlite.Test.{TenantBinder, TenantedPost}

  require Ash.Query

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ash_sqlite_multitenancy_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    repos =
      Map.new(["acme", "globex"], fn tenant ->
        path = Path.join(dir, "#{tenant}.db")
        {:ok, pid} = AshSqlite.TenantRepo.start_link(name: nil, database: path, pool_size: 1)

        Ecto.Adapters.SQL.query!(
          pid,
          "CREATE TABLE tenanted_posts (id TEXT PRIMARY KEY, title TEXT)",
          []
        )

        TenantBinder.register(tenant, pid)
        {tenant, %{pid: pid, path: path}}
      end)

    TenantBinder.reset_calls()

    %{repos: repos}
  end

  # Goes to the file rather than back through Ash, so the isolation claim is checked
  # against bytes on disk and not against the layer being tested.
  defp titles_in_file(path) do
    {:ok, db} = Exqlite.Sqlite3.open(path)
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "SELECT title FROM tenanted_posts ORDER BY title")
    {:ok, rows} = Exqlite.Sqlite3.fetch_all(db, stmt)
    :ok = Exqlite.Sqlite3.close(db)
    List.flatten(rows)
  end

  defp create!(tenant, title) do
    TenantedPost
    |> Ash.Changeset.for_create(:create, %{title: title}, tenant: tenant)
    |> Ash.create!()
  end

  test "the data layer accepts context multitenancy" do
    assert Ash.DataLayer.data_layer_can?(TenantedPost, :multitenancy)
  end

  test "each tenant's rows land in that tenant's own file", %{repos: repos} do
    create!("acme", "acme one")
    create!("acme", "acme two")
    create!("globex", "globex one")

    assert titles_in_file(repos["acme"].path) == ["acme one", "acme two"]
    assert titles_in_file(repos["globex"].path) == ["globex one"]
  end

  test "a read only sees its own tenant" do
    create!("acme", "acme one")
    create!("globex", "globex one")

    assert ["acme one"] = TenantedPost |> Ash.read!(tenant: "acme") |> Enum.map(& &1.title)
    assert ["globex one"] = TenantedPost |> Ash.read!(tenant: "globex") |> Enum.map(& &1.title)
  end

  test "aggregates are bound, which a caller could not have wrapped" do
    # `Ash.count/2` never enters `Ash.Actions.Read`, so a preparation or an
    # around_transaction hook cannot reach it. Binding in the data layer does.
    create!("acme", "acme one")
    create!("globex", "globex one")
    create!("globex", "globex two")

    assert Ash.count!(TenantedPost, tenant: "acme") == 1
    assert Ash.count!(TenantedPost, tenant: "globex") == 2
  end

  test "atomic updates are bound", %{repos: repos} do
    # Ash builds these as one statement with no changeset for a caller to hook.
    create!("acme", "before")

    TenantedPost
    |> Ash.Query.filter(title == "before")
    |> Ash.bulk_update!(:update, %{title: "after"}, tenant: "acme", strategy: :atomic)

    assert titles_in_file(repos["acme"].path) == ["after"]
  end

  test "reads are reported to the binder as reads" do
    create!("acme", "one")
    TenantBinder.reset_calls()

    Ash.read!(TenantedPost, tenant: "acme")

    assert TenantBinder.calls() != []
    assert Enum.all?(TenantBinder.calls(), &match?({"acme", :read}, &1))
  end

  test "a write reports both the transaction and the write inside it" do
    TenantBinder.reset_calls()
    create!("acme", "two")

    usages = TenantBinder.calls() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    assert :transaction in usages
    assert :write in usages
  end

  test "Ash refuses a tenantless query before it reaches the data layer" do
    # `set_tenant/3` is a no-op on the query, but declaring the strategy is what
    # makes Ash enforce "tenant required unless global?" — which is most of why the
    # callback exists at all.
    assert_raise Ash.Error.Invalid, ~r/require a tenant to be specified/, fn ->
      Ash.read!(TenantedPost)
    end
  end

  test "and the data layer refuses one too, for the paths that bypass an action" do
    assert_raise ArgumentError, ~r/carried no tenant/, fn ->
      AshSqlite.DataLayer.transaction(TenantedPost, fn -> :unreachable end)
    end
  end

  test "a transaction commits to the tenant's own database", %{repos: repos} do
    create!("acme", "in a transaction")

    assert titles_in_file(repos["acme"].path) == ["in a transaction"]
    assert titles_in_file(repos["globex"].path) == []
  end

  test "a transaction refuses to reach into another tenant's database" do
    # Wrapped by Ash, since the inner statement is a real action.
    assert_raise Ash.Error.Unknown, ~r/open on a different tenant/, fn ->
      AshSqlite.DataLayer.transaction(
        TenantedPost,
        fn -> create!("globex", "wrong database") end,
        nil,
        %{type: :custom, metadata: %{}, data_layer_context: %{tenant: "acme"}}
      )
    end
  end
end
