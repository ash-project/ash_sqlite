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
  alias AshSqlite.MultiTenancy.Binds
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

    # Every caller of a cold tenant races the same activation. One connection per
    # database is the whole invariant -- two would be two writers on one file.
    test "concurrent first requests for one cold tenant share one connection", %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))

      results =
        1..50
        |> Task.async_stream(fn _ -> MultiTenancy.connection_for(@repo, "acme") end,
          max_concurrency: 50
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, _}, &1)), inspect(Enum.uniq(results))
      assert results |> Enum.map(fn {:ok, pid} -> pid end) |> Enum.uniq() |> length() == 1
    end

    test "gives each tenant its own connection", %{dir: dir} do
      start_tenancy(dir)

      {:ok, acme} = MultiTenancy.connection_for(@repo, "acme")
      {:ok, globex} = MultiTenancy.connection_for(@repo, "globex")

      refute acme == globex
    end
  end

  describe "a fleet that was never started" do
    test "connection_for/2 names what is missing, not an internal registry" do
      assert_raise RuntimeError, fn -> MultiTenancy.connection_for(@repo, "acme") end

      message =
        try do
          MultiTenancy.connection_for(@repo, "acme")
        rescue
          e -> Exception.message(e)
        end

      assert message =~ "has no tenant fleet running"
      assert message =~ "{AshSqlite.MultiTenancy,"
      assert message =~ "tenant_binder"
      refute message =~ "unknown registry"
    end

    test "with_tenant/3 says the same thing" do
      assert_raise RuntimeError, ~r/has no tenant fleet running/, fn ->
        MultiTenancy.with_tenant(@repo, "acme", fn -> :never end)
      end
    end

    # A started fleet asked about a tenant it cannot serve must still report that,
    # rather than being mistaken for a missing supervision tree.
    test "a real error from a started fleet is not rewritten", %{dir: dir} do
      start_tenancy(dir)

      assert :ok = MultiTenancy.seal(@repo)
      assert {:error, :draining} = MultiTenancy.connection_for(@repo, "acme")
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

    # Eviction picks a tenant nothing is bound to and then closes it, and the two
    # steps are not one atomic act. A request that arrives in between must not lose
    # its statement, so the whole cycle is driven under contention rather than in
    # the sequential order the tests above use.
    test "statements survive eviction churn under contention", %{dir: dir} do
      start_tenancy(dir, max_resident: 1, migrations_path: migrations(dir))

      outcomes =
        1..40
        |> Task.async_stream(
          fn i ->
            tenant = "t#{rem(i, 3)}"

            try do
              write(tenant, "row #{i}")
              read(tenant)
              :ok
            rescue
              exception -> {:error, Exception.message(exception)}
            catch
              kind, reason -> {kind, reason}
            end
          end,
          max_concurrency: 8,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, outcome} -> outcome end)

      assert Enum.reject(outcomes, &(&1 == :ok)) == []
    end

    test "eviction churn does not move rows between tenants", %{dir: dir} do
      start_tenancy(dir, max_resident: 1, migrations_path: migrations(dir))

      for i <- 1..10 do
        write("acme", "acme #{i}")
        write("globex", "globex #{i}")
      end

      acme = List.flatten(read("acme"))
      globex = List.flatten(read("globex"))

      assert length(acme) == 10
      assert length(globex) == 10
      assert Enum.all?(acme, &String.starts_with?(&1, "acme"))
      assert Enum.all?(globex, &String.starts_with?(&1, "globex"))
    end

    test "close/3 refuses a tenant with a statement in flight", %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))
      write("acme", "in use")
      holder = hold("acme")

      assert {:error, :busy} = MultiTenancy.close(@repo, "acme", grace_ms: 20)
      assert MultiTenancy.resident(@repo) == ["acme"]

      release(holder)
    end

    test "close/3 with force: true closes it regardless", %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))
      write("acme", "in use")
      holder = hold("acme")

      assert :ok = MultiTenancy.close(@repo, "acme", force: true)
      assert MultiTenancy.resident(@repo) == []

      release(holder)
    end

    test "close/3 waits for a statement to finish rather than refusing at once",
         %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))
      write("acme", "in use")
      holder = hold("acme")

      Task.start(fn ->
        Process.sleep(20)
        release(holder)
      end)

      assert :ok = MultiTenancy.close(@repo, "acme", grace_ms: 2_000)
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

    # A deleted tenant is one that has never been seen, not one that is broken: the
    # next request must get a fresh, migrated database rather than a quarantine or
    # the rows that were just removed.
    test "a tenant requested again after a delete gets a fresh migrated database",
         %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))
      write("acme", "gone")

      assert {:ok, _removed} = MultiTenancy.delete(@repo, "acme")
      assert MultiTenancy.quarantined(@repo) == %{}

      write("acme", "new")

      assert read("acme") == [["new"]]
    end
  end

  describe "holding a tenant closed" do
    # `rename/3` and `delete/2` both mark a tenant closing, close it, and then move
    # or unlink its file. The mark is what stops a request arriving in between and
    # opening the very file that is about to be moved, so `close/3` must leave a
    # mark its caller took.
    test "close/3 leaves a closing mark its caller was already holding", %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))
      write("acme", "held")

      Binds.begin_closing(@repo, "acme")
      MultiTenancy.close(@repo, "acme")

      assert Binds.closing?(@repo, "acme")
      assert Binds.bound(@repo, "acme") == :closing
    end

    test "close/3 clears a mark it took itself", %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))
      write("acme", "not held")

      MultiTenancy.close(@repo, "acme")

      refute Binds.closing?(@repo, "acme")
      assert Binds.bound(@repo, "acme") == :ok
    end

    # The window `rename/3` opens between its own close and its file move: a bind
    # arriving here must wait for the move rather than opening the source file. Run
    # as `rename/3` runs it, because the bug is in the sequence and not in one call.
    test "nothing can bind the source name mid-rename", %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))
      write("acme", "original")

      Binds.begin_closing(@repo, "acme")
      Binds.begin_closing(@repo, "acme-renamed")

      MultiTenancy.close(@repo, "acme")

      assert Binds.bound(@repo, "acme") == :closing,
             "a write addressed to acme here opens the file rename/3 is moving, " <>
               "so it commits into acme-renamed's database instead"

      assert Binds.bound(@repo, "acme-renamed") == :closing

      Binds.end_closing(@repo, "acme")
      Binds.end_closing(@repo, "acme-renamed")
    end

    # `delete/2`'s window is worse than rename's: a bind here leaves a connection
    # open on the inode `delete/2` is about to unlink, and it goes on serving reads
    # and accepting writes against a database with no directory entry.
    test "nothing can bind a tenant mid-delete", %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))
      write("acme", "doomed")

      Binds.begin_closing(@repo, "acme")
      MultiTenancy.close(@repo, "acme", force: true)

      assert Binds.bound(@repo, "acme") == :closing,
             "a request arriving between delete/2's close and its unlink reopens " <>
               "the database, which then survives the delete and keeps serving"

      Binds.end_closing(@repo, "acme")
    end

    test "delete/2 leaves no connection open on a database it removed", %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))
      write("acme", "doomed")

      assert {:ok, _removed} = MultiTenancy.delete(@repo, "acme")

      # A tenant may legitimately be resident again already -- a request after the
      # delete recreates the file. What must never hold is residency with no file.
      for tenant <- MultiTenancy.resident(@repo) do
        assert File.exists?(Database.path(dir, tenant)),
               "#{tenant} is resident but its database is gone, so it is serving " <>
                 "an unlinked inode whose writes are discarded on close"
      end
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

    # A statement in flight holds the old inode, so a move under it would commit
    # into the destination's database. Refused, as the close it rests on is.
    test "refuses a tenant with a statement in flight, leaving the file alone",
         %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))
      write("acme", "in use")
      holder = hold("acme")

      assert {:error, :busy} = MultiTenancy.rename(@repo, "acme", "acme-renamed")

      assert File.exists?(Database.path(dir, "acme"))
      refute File.exists?(Database.path(dir, "acme-renamed"))

      release(holder)
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

    # `close_after?` frees residency; it is not part of migrating. A tenant serving
    # traffic must not be reported as a migration failure, and must not be closed
    # out from under the traffic either.
    test "a tenant in use is migrated, left resident, and still reported ok",
         %{dir: dir} do
      start_tenancy(dir, migrations_path: migrations(dir))
      write("acme", "in use")
      holder = hold("acme")

      assert [{"acme", {:ok, 20_260_101_000_000}}] =
               MultiTenancy.migrate_all(@repo, ["acme"], grace_ms: 20)

      assert MultiTenancy.resident(@repo) == ["acme"]

      release(holder)
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
