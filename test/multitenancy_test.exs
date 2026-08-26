# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MultitenancyTest do
  @moduledoc """
  Context multitenancy against two real database files, checked by reading each file.
  """
  use ExUnit.Case, async: false

  alias AshSqlite.Test.{GlobalPost, TenantBinder, TenantedPost}

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

        Ecto.Adapters.SQL.query!(
          pid,
          "CREATE TABLE global_posts (id TEXT PRIMARY KEY, title TEXT)",
          []
        )

        TenantBinder.register(tenant, pid)
        {tenant, %{pid: pid, path: path}}
      end)

    TenantBinder.reset_calls()

    # The tenant files are made per test, but the shared database is not: it is the
    # repo module's own, and it outlives every test that writes to it.
    Ecto.Adapters.SQL.query!(AshSqlite.TenantRepo, "DELETE FROM global_posts", [])

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

  defp titles(tenant) do
    TenantedPost |> Ash.read!(tenant: tenant) |> Enum.map(& &1.title) |> Enum.sort()
  end

  defp create!(tenant, title) do
    TenantedPost
    |> Ash.Changeset.for_create(:create, %{title: title}, tenant: tenant)
    |> Ash.create!()
  end

  test "the data layer accepts context multitenancy" do
    assert Ash.DataLayer.data_layer_can?(TenantedPost, :multitenancy)
  end

  test "a resource that names a binder gets that one, not the default" do
    assert AshSqlite.DataLayer.Info.tenant_binder(TenantedPost) == TenantBinder
  end

  test "the named binder is what actually runs" do
    TenantBinder.reset_calls()
    create!("acme", "one")

    assert TenantBinder.calls() != []
  end

  test "a tenant given to Ash.create/3 rather than to the changeset still arrives" do
    post =
      TenantedPost
      |> Ash.Changeset.for_create(:create, %{title: "late tenant"})
      |> Ash.create!(tenant: "acme")

    assert post.title == "late tenant"
    assert titles("acme") == ["late tenant"]
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
    create!("acme", "acme one")
    create!("globex", "globex one")
    create!("globex", "globex two")

    assert Ash.count!(TenantedPost, tenant: "acme") == 1
    assert Ash.count!(TenantedPost, tenant: "globex") == 2
  end

  test "atomic updates are bound", %{repos: repos} do
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
    assert_raise Ash.Error.Unknown, ~r/open on another tenant's database/, fn ->
      AshSqlite.DataLayer.transaction(
        TenantedPost,
        fn -> create!("globex", "wrong database") end,
        nil,
        %{type: :custom, metadata: %{}, data_layer_context: %{tenant: "acme"}}
      )
    end
  end

  describe "a global? resource" do
    # One copy of the rows, as `global?` means for a schema-based data layer. The
    # tenant is ignored rather than honoured: honouring it gave every tenant its own
    # copy of a table that is supposed to have exactly one.
    test "a write goes to the shared database, not the tenant's file", %{repos: repos} do
      GlobalPost
      |> Ash.Changeset.for_create(:create, %{title: "shared"}, tenant: "acme")
      |> Ash.create!()

      assert shared_global_titles() == ["shared"]
      assert global_titles_in_file(repos["acme"].path) == []
      assert global_titles_in_file(repos["globex"].path) == []
    end

    test "every tenant sees the same rows" do
      GlobalPost
      |> Ash.Changeset.for_create(:create, %{title: "one copy"}, tenant: "acme")
      |> Ash.create!()

      assert global_titles("acme") == ["one copy"]
      assert global_titles("globex") == ["one copy"]
      assert Ash.read!(GlobalPost) |> Enum.map(& &1.title) == ["one copy"]
    end

    # The footgun this replaces: the resource shares a repo module with tenanted
    # ones, so leaving the process binding alone made it read whichever tenant was
    # bound last. It now binds the module's own instance explicitly.
    test "is unaffected by a tenant bound on the same repo module" do
      GlobalPost
      |> Ash.Changeset.for_create(:create, %{title: "shared"}, tenant: "acme")
      |> Ash.create!()

      assert bound("acme", fn -> Ash.read!(GlobalPost) |> Enum.map(& &1.title) end) ==
               ["shared"]

      assert bound("globex", fn -> Ash.read!(GlobalPost) |> Enum.map(& &1.title) end) ==
               ["shared"]
    end

    test "is read without a tenant, where a tenanted resource is refused" do
      assert_raise Ash.Error.Invalid, ~r/require a tenant to be specified/, fn ->
        Ash.read!(TenantedPost)
      end

      assert Ash.read!(GlobalPost) == []
    end

    test "is never asked of the binder, with or without a tenant" do
      TenantBinder.reset_calls()

      GlobalPost
      |> Ash.Changeset.for_create(:create, %{title: "shared"}, tenant: "acme")
      |> Ash.create!()

      Ash.read!(GlobalPost)

      assert TenantBinder.calls() == []
    end

    # The shape this is easy to arrive at: adding `global? true` to a resource on a
    # repo module that only ever served tenants. Such a module is reached entirely
    # through `put_dynamic_repo/1`, so it has no named process and no shared database
    # to hold the one copy.
    test "says so when the shared repo has no instance of its own" do
      message =
        try do
          Ash.read!(AshSqlite.Test.UnstartedGlobalPost)
        rescue
          error -> Exception.message(error)
        end

      assert message =~ "one shared database rather than one per tenant"
      assert message =~ "AshSqlite.ManagedTenantRepo"
      assert message =~ ~s(database: "priv/shared.db")
      refute message =~ "could not lookup Ecto repo"
    end

    # Started under its own name but with no database: the other way to have no
    # shared database, and the one whose native failure is unrecognisable -- the
    # statement waits out the pool timeout and then reports that requests are
    # arriving faster than they can be served.
    test "says so when the shared repo is named but has no database" do
      {:ok, pid} = AshSqlite.ManagedTenantRepo.start_link()

      # A repo with no database cannot keep a connection up, so it may already be on
      # its way down by the time this runs.
      on_exit(fn ->
        try do
          if Process.alive?(pid), do: Supervisor.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end)

      assert is_nil(AshSqlite.ManagedTenantRepo.config()[:database])

      message =
        try do
          Ash.read!(AshSqlite.Test.UnstartedGlobalPost)
        rescue
          error -> Exception.message(error)
        end

      assert message =~ "has no `database:` set"
      refute message =~ "connection not available"
    end

    test "restores the caller's binding afterwards" do
      bound("acme", fn ->
        before = AshSqlite.TenantRepo.get_dynamic_repo()
        Ash.read!(GlobalPost)
        assert AshSqlite.TenantRepo.get_dynamic_repo() == before
      end)
    end
  end

  defp bound(tenant, fun) do
    previous = AshSqlite.TenantRepo.put_dynamic_repo(TenantBinder.repo_for(tenant))

    try do
      fun.()
    after
      AshSqlite.TenantRepo.put_dynamic_repo(previous)
    end
  end

  defp shared_global_titles do
    AshSqlite.TenantRepo
    |> Ecto.Adapters.SQL.query!("SELECT title FROM global_posts ORDER BY title", [])
    |> Map.fetch!(:rows)
    |> List.flatten()
  end

  defp global_titles(tenant) do
    GlobalPost |> Ash.read!(tenant: tenant) |> Enum.map(& &1.title) |> Enum.sort()
  end

  defp global_titles_in_file(path) do
    {:ok, db} = Exqlite.Sqlite3.open(path)
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "SELECT title FROM global_posts ORDER BY title")
    {:ok, rows} = Exqlite.Sqlite3.fetch_all(db, stmt)
    :ok = Exqlite.Sqlite3.close(db)
    List.flatten(rows)
  end
end
