# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.TableRebuildTest do
  @moduledoc """
  Generates migrations for resources that change in ways SQLite cannot do in place, runs them
  on a real SQLite file and checks what happens to the data.
  """
  use ExUnit.Case, async: false
  @moduletag :migration
  @moduletag :rebuild
  @moduletag :tmp_dir

  import AshSqlite.RebuildHelper

  setup %{tmp_dir: tmp_dir} = context do
    current_shell = Mix.shell()
    :ok = Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(current_shell) end)

    %{
      ctx:
        start(
          tmp_dir,
          Map.get(context, :repo_config, []),
          Map.get(context, :repo, AshSqlite.RebuildTestRepo)
        )
    }
  end

  # Defines a resource on the rebuild test repo. Redefining a module is how a test
  # moves a resource from one version to the next.
  defmacrop defres(mod, table, do: body) do
    quote do
      defres_on(AshSqlite.RebuildTestRepo, unquote(mod), unquote(table), do: unquote(body))
    end
  end

  defmacrop defres_on(repo, mod, table, do: body) do
    quote do
      Code.compiler_options(ignore_module_conflict: true)

      defmodule unquote(mod) do
        use Ash.Resource,
          domain: nil,
          data_layer: AshSqlite.DataLayer

        sqlite do
          table unquote(table)
          repo(unquote(repo))
        end

        actions do
          defaults([:create, :read, :update, :destroy])
        end

        unquote(body)
      end

      Code.compiler_options(ignore_module_conflict: false)
    end
  end

  defmacrop defdomain(resources) do
    quote do
      Code.compiler_options(ignore_module_conflict: true)

      defmodule Domain do
        use Ash.Domain, validate_config_inclusion?: false

        resources do
          for resource <- unquote(resources) do
            resource(resource)
          end
        end
      end

      Code.compiler_options(ignore_module_conflict: false)
    end
  end

  describe "making a column nullable" do
    test "keeps the rows and the child rows that cascade from them", %{ctx: ctx} do
      defres Parent, "parents" do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, allow_nil?: false)
        end
      end

      defres Child, "children" do
        attributes do
          uuid_primary_key(:id)
        end

        relationships do
          belongs_to(:parent, Parent, allow_nil?: false)
        end

        sqlite do
          references do
            reference(:parent, on_delete: :delete)
          end
        end
      end

      defdomain([Parent, Child])
      generate(Domain, ctx)
      migrate(ctx)

      sql("INSERT INTO parents (id, name) VALUES ('p1', 'one'), ('p2', 'two')")
      sql("INSERT INTO children (id, parent_id) VALUES ('c1', 'p1'), ('c2', 'p2')")

      defres Parent, "parents" do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string)
        end
      end

      generate(Domain, ctx)
      migration = last_migration(ctx)
      assert migration =~ "use AshSqlite.Migration"
      migrate(ctx)

      assert sql("SELECT id, name FROM parents ORDER BY id") == [["p1", "one"], ["p2", "two"]]
      assert sql("SELECT id FROM children ORDER BY id") == [["c1"], ["c2"]]
      assert fk_violations() == []

      assert [%{name: "name", notnull: false}] =
               Enum.filter(columns("parents"), &(&1.name == "name"))
    end
  end

  # A resource on the table "items", the one most scenarios change.
  defmacrop defitem(do: body) do
    quote do
      defres Item, "items" do
        unquote(body)
      end

      defdomain([Item])
    end
  end

  describe "making a column required" do
    test "without a default, fails loudly when a row holds NULL and leaves nothing behind", %{
      ctx: ctx
    } do
      defitem do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string)
        end
      end

      generate(Domain, ctx)
      migrate(ctx)
      sql("INSERT INTO items (id, name) VALUES ('a', 'x'), ('b', NULL)")
      versions_before = versions()

      defitem do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, allow_nil?: false)
        end
      end

      generate(Domain, ctx)
      assert migrate_error(ctx) =~ "NOT NULL constraint failed"

      assert leftovers() == []
      assert versions() == versions_before
      assert sql("SELECT id, name FROM items ORDER BY id") == [["a", "x"], ["b", nil]]

      assert [%{name: "name", notnull: false}] =
               Enum.filter(columns("items"), &(&1.name == "name"))
    end

    test "with a default, fills the NULLs with it", %{ctx: ctx} do
      defitem do
        sqlite do
          migration_defaults(name: "\"unnamed\"")
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string)
        end
      end

      generate(Domain, ctx)
      migrate(ctx)
      sql("INSERT INTO items (id, name) VALUES ('a', 'x'), ('b', NULL)")

      defitem do
        sqlite do
          migration_defaults(name: "\"unnamed\"")
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, allow_nil?: false, default: "unnamed")
        end
      end

      generate(Domain, ctx)
      assert last_migration(ctx) =~ "COALESCE"
      migrate(ctx)

      assert sql("SELECT id, name FROM items ORDER BY id") == [["a", "x"], ["b", "unnamed"]]
    end
  end

  describe "adding a required column without a default" do
    test "works on an empty table and fails loudly on a table with rows", %{ctx: ctx} do
      defitem do
        attributes do
          uuid_primary_key(:id)
        end
      end

      generate(Domain, ctx)
      migrate(ctx)

      defitem do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, allow_nil?: false)
        end
      end

      generate(Domain, ctx)
      sql("INSERT INTO items (id) VALUES ('a')")
      assert migrate_error(ctx) =~ "NOT NULL constraint failed: items_rebuild.name"
      assert leftovers() == []
      assert sql("SELECT id FROM items") == [["a"]]

      sql("DELETE FROM items")
      migrate(ctx)

      assert [%{name: "name", notnull: true}] =
               Enum.filter(columns("items"), &(&1.name == "name"))
    end
  end

  describe "defaults that are not literals" do
    test "a new column keeps its SQL default for the rows that exist", %{ctx: ctx} do
      defitem do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string)
        end
      end

      generate(Domain, ctx)
      migrate(ctx)
      sql("INSERT INTO items (id, name) VALUES ('a', 'x'), ('b', 'y')")

      defitem do
        sqlite do
          migration_defaults(stamp: "fragment(\"(datetime('now'))\")")
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, allow_nil?: false, default: "z")
          attribute(:stamp, :string)
        end
      end

      generate(Domain, ctx)
      migrate(ctx)

      assert [[stamp_a], [stamp_b]] = sql("SELECT stamp FROM items ORDER BY id")
      assert is_binary(stamp_a) and is_binary(stamp_b)
    end
  end

  describe "foreign key topology" do
    test "a self-referencing table", %{ctx: ctx} do
      defres Node, "nodes" do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, allow_nil?: false)
        end

        relationships do
          belongs_to(:parent, Node)
        end

        sqlite do
          references do
            reference(:parent, on_delete: :delete)
          end
        end
      end

      defdomain([Node])
      generate(Domain, ctx)
      migrate(ctx)

      sql(
        "INSERT INTO nodes (id, name, parent_id) VALUES ('root', 'r', NULL), ('kid', 'k', 'root')"
      )

      defres Node, "nodes" do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string)
        end

        relationships do
          belongs_to(:parent, Node)
        end

        sqlite do
          references do
            reference(:parent, on_delete: :delete)
          end
        end
      end

      generate(Domain, ctx)
      migrate(ctx)

      assert sql("SELECT id, parent_id FROM nodes ORDER BY id") == [
               ["kid", "root"],
               ["root", nil]
             ]

      assert fk_violations() == []
      # still a working cascade pointing at the table itself
      sql("DELETE FROM nodes WHERE id = 'root'")
      assert sql("SELECT id FROM nodes") == []
    end

    test "a new column with a foreign key can be rolled back", %{ctx: ctx} do
      defres Owner, "owners" do
        attributes do
          uuid_primary_key(:id)
        end
      end

      defres Pet, "pets" do
        attributes do
          uuid_primary_key(:id)
        end
      end

      defdomain([Owner, Pet])
      generate(Domain, ctx)
      migrate(ctx)
      sql("INSERT INTO pets (id) VALUES ('p')")

      defres Pet, "pets" do
        attributes do
          uuid_primary_key(:id)
        end

        relationships do
          belongs_to(:owner, Owner)
        end
      end

      generate(Domain, ctx)
      migrate(ctx)
      assert [[_, _, "owners" | _]] = sql("PRAGMA foreign_key_list(pets)")

      rollback(ctx)
      assert Enum.map(columns("pets"), & &1.name) == ["id"]
      assert sql("SELECT id FROM pets") == [["p"]]
      assert fk_violations() == []
    end

    test "a table created in the same migration that references the rebuilt one", %{ctx: ctx} do
      defres Parent, "parents" do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, allow_nil?: false)
        end
      end

      defdomain([Parent])
      generate(Domain, ctx)
      migrate(ctx)
      sql("INSERT INTO parents (id, name) VALUES ('p', 'n')")

      defres Parent, "parents" do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string)
        end
      end

      defres Child, "children" do
        attributes do
          uuid_primary_key(:id)
        end

        relationships do
          belongs_to(:parent, Parent, allow_nil?: false)
        end

        sqlite do
          references do
            reference(:parent, on_delete: :delete)
          end
        end
      end

      defdomain([Parent, Child])
      generate(Domain, ctx)
      migrate(ctx)

      sql("INSERT INTO children (id, parent_id) VALUES ('c', 'p')")
      assert fk_violations() == []
      sql("DELETE FROM parents")
      assert sql("SELECT id FROM children") == []
    end
  end

  describe "deferrable foreign keys" do
    test "a deferrable reference next to a rebuild says it is not applied", %{ctx: ctx} do
      defres Parent, "parents" do
        attributes do
          uuid_primary_key(:id)
        end
      end

      defres Child, "children" do
        attributes do
          uuid_primary_key(:id)
        end

        relationships do
          belongs_to(:parent, Parent)
        end
      end

      defdomain([Parent, Child])
      generate(Domain, ctx)
      migrate(ctx)

      defres Child, "children" do
        attributes do
          uuid_primary_key(:id)
          attribute(:note, :string, allow_nil?: false)
        end

        relationships do
          belongs_to(:parent, Parent)
        end

        sqlite do
          references do
            reference(:parent, deferrable: :initially)
          end
        end
      end

      generate(Domain, ctx)
      migration = last_migration(ctx)
      assert migration =~ "NOT APPLIED: the foreign key children_parent_id_fkey is deferrable"
      migrate(ctx)
      assert fk_violations() == []
    end
  end

  # Two versions of the resource on "items": `name` required, then optional.
  defmacrop items_v1 do
    quote do
      defitem do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, allow_nil?: false)
        end
      end
    end
  end

  defmacrop items_v2 do
    quote do
      defitem do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string)
        end
      end
    end
  end

  describe "how the migration is run" do
    test "rolling back the rebuild with data that fits", %{ctx: ctx} do
      items_v1()
      generate(Domain, ctx)
      migrate(ctx)

      items_v2()
      generate(Domain, ctx)
      migrate(ctx)
      sql("INSERT INTO items (id, name) VALUES ('a', 'x')")
      rollback(ctx)

      assert [%{name: "name", notnull: true}] =
               Enum.filter(columns("items"), &(&1.name == "name"))

      assert sql("SELECT id, name FROM items") == [["a", "x"]]
      assert versions() |> length() == 1
    end
  end

  defp assert_raise_on_rollback(ctx, message) do
    error =
      try do
        rollback(ctx)
        flunk("expected the rollback to fail")
      rescue
        error in ExUnit.AssertionError -> reraise error, __STACKTRACE__
        error -> Exception.message(error)
      end

    assert error =~ message
  end

  describe "the generator" do
    test "generating again after a rebuild migration finds nothing to do (codegen --check)", %{
      ctx: ctx
    } do
      items_v1()
      generate(Domain, ctx)
      migrate(ctx)
      items_v2()
      generate(Domain, ctx)
      migrate(ctx)

      files = migrations(ctx)
      assert generate(Domain, ctx) == files
      assert generate(Domain, ctx, check: true) == files
    end

    test "the formatted migration is valid and runs", %{ctx: ctx} do
      items_v1()
      generate(Domain, ctx, format: true)
      migrate(ctx)
      sql("INSERT INTO items (id, name) VALUES ('a', 'x')")
      items_v2()
      generate(Domain, ctx, format: true)
      migrate(ctx)
      assert sql("SELECT id, name FROM items") == [["a", "x"]]
    end

    test "a column removed from the resource is kept (nullable) by the rebuild", %{ctx: ctx} do
      defitem do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, allow_nil?: false)
          attribute(:legacy, :string, allow_nil?: false)
        end
      end

      generate(Domain, ctx)
      migrate(ctx)
      sql("INSERT INTO items (id, name, legacy) VALUES ('a', 'x', 'old data')")

      items_v2()
      generate(Domain, ctx)
      migrate(ctx)

      assert sql("SELECT id, name, legacy FROM items") == [["a", "x", "old data"]]
      assert [%{notnull: false}] = Enum.filter(columns("items"), &(&1.name == "legacy"))

      # a row written after: the resource no longer knows `legacy`, so it is NULL
      sql("INSERT INTO items (id, name) VALUES ('b', 'y')")
      # going back would need a value for the required column `legacy`
      assert_raise_on_rollback(ctx, "NOT NULL constraint failed")
      assert length(sql("SELECT id FROM items")) == 2
    end
  end

  defp index_sql(table) do
    sql(
      "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = ? AND sql IS NOT NULL ORDER BY name",
      [
        table
      ]
    )
  end

  defmacrop indexed_items(nullable?) do
    quote do
      defitem do
        sqlite do
          custom_indexes do
            index([:name], where: "name IS NOT NULL", name: "items_partial_index")
          end
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, allow_nil?: unquote(!nullable?), public?: true)
          attribute(:code, :string, public?: true)
        end

        identities do
          identity(:unique_code, [:code])
          identity(:unique_live_name, [:name], where: expr(not is_nil(^ref(:code))))
        end
      end
    end
  end

  defmacrop retyped_items(type, strict?) do
    quote do
      defitem do
        sqlite do
          strict?(unquote(strict?))
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:amount, unquote(type))
        end
      end
    end
  end

  describe "resource shapes" do
    test "a composite primary key", %{ctx: ctx} do
      defitem do
        attributes do
          attribute(:org, :string, primary_key?: true, allow_nil?: false)
          attribute(:code, :string, primary_key?: true, allow_nil?: false)
          attribute(:name, :string, allow_nil?: false)
        end
      end

      generate(Domain, ctx)
      migrate(ctx)
      sql("INSERT INTO items (org, code, name) VALUES ('o', 'c', 'x')")

      defitem do
        attributes do
          attribute(:org, :string, primary_key?: true, allow_nil?: false)
          attribute(:code, :string, primary_key?: true, allow_nil?: false)
          attribute(:name, :string)
        end
      end

      generate(Domain, ctx)
      migrate(ctx)

      assert sql("SELECT org, code, name FROM items") == [["o", "c", "x"]]
      assert Enum.map(columns("items"), & &1.pk) |> Enum.sort() == [0, 1, 2]

      assert_raise Exqlite.Error, ~r/UNIQUE constraint failed/, fn ->
        sql("INSERT INTO items (org, code, name) VALUES ('o', 'c', 'dup')")
      end
    end

    test "a primary key that changes is listed as such", %{ctx: ctx} do
      defitem do
        attributes do
          uuid_primary_key(:id)
          attribute(:code, :string, allow_nil?: false)
        end
      end

      generate(Domain, ctx)
      migrate(ctx)
      sql("INSERT INTO items (id, code) VALUES ('a', 'c')")

      defitem do
        attributes do
          uuid_primary_key(:id)
          attribute(:code, :string, primary_key?: true, allow_nil?: false)
        end
      end

      generate(Domain, ctx)
      assert last_migration(ctx) =~ "# - changing the primary key"
      refute last_migration(ctx) =~ "Operation"

      migrate(ctx)
      assert Enum.map(columns("items"), & &1.pk) |> Enum.sort() == [1, 2]
    end

    test "identities with a where, custom indexes with where",
         %{ctx: ctx} do
      indexed_items(false)
      generate(Domain, ctx)
      migrate(ctx)
      before = index_sql("items")
      assert length(before) == 3

      indexed_items(true)
      generate(Domain, ctx)
      migrate(ctx)

      assert index_sql("items") == before
    end

    test "a table named like the temporary one is refused loudly, not overwritten", %{ctx: ctx} do
      defres Other, "items_rebuild" do
        attributes do
          uuid_primary_key(:id)
        end
      end

      items_v1()
      defdomain([Item, Other])
      generate(Domain, ctx)
      migrate(ctx)
      sql("INSERT INTO items_rebuild (id) VALUES ('keep me')")

      items_v2()
      defdomain([Item, Other])
      generate(Domain, ctx)
      assert migrate_error(ctx) =~ "already exists"
      assert sql("SELECT id FROM items_rebuild") == [["keep me"]]
    end
  end

  describe "changing a column's type" do
    defp retype(ctx, strict?) do
      retyped_items(:string, strict?)

      generate(__MODULE__.Domain, ctx)
      migrate(ctx)
      sql("INSERT INTO items (id, amount) VALUES ('a', '12'), ('b', 'twelve')")

      retyped_items(:integer, strict?)

      generate(__MODULE__.Domain, ctx)
    end

    test "in a STRICT table a value that is not a number is loud", %{ctx: ctx} do
      retype(ctx, true)
      refute last_migration(ctx) =~ "not STRICT"
      assert migrate_error(ctx) =~ "cannot store TEXT value in INTEGER column"
      assert sql("SELECT id, amount FROM items ORDER BY id") == [["a", "12"], ["b", "twelve"]]
    end

    test "in a table that is not STRICT it is copied as it is, text in an integer column", %{
      ctx: ctx
    } do
      retype(ctx, false)
      assert last_migration(ctx) =~ "REVIEW: `amount` changes type in a table that is not STRICT"
      migrate(ctx)

      assert sql("SELECT id, amount, typeof(amount) FROM items ORDER BY id") == [
               ["a", 12, "integer"],
               ["b", "twelve", "text"]
             ]
    end
  end

  describe "dropping columns" do
    test "--drop-columns drops the column instead of keeping it", %{ctx: ctx} do
      defitem do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, allow_nil?: false)
          attribute(:legacy, :string)
        end
      end

      generate(Domain, ctx)
      migrate(ctx)
      sql("INSERT INTO items (id, name, legacy) VALUES ('a', 'x', 'old')")

      items_v2()
      generate(Domain, ctx, drop_columns: true)
      refute last_migration(ctx) =~ "no longer in the resource"
      migrate(ctx)

      assert Enum.map(columns("items"), & &1.name) == ["id", "name"]
    end
  end

  defmacrop filtered_items(nullable?) do
    quote do
      defitem do
        sqlite do
          base_filter_sql("name IS NOT NULL")
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, allow_nil?: unquote(!nullable?), public?: true)
        end

        identities do
          identity(:unique_name, [:name])
        end
      end
    end
  end

  describe "keys and filters" do
    test "a resource's base filter on its identities", %{ctx: ctx} do
      filtered_items(false)
      generate(Domain, ctx)
      migrate(ctx)
      before = index_sql("items")
      assert [[_, index_sql]] = before
      assert index_sql =~ "WHERE"

      filtered_items(true)
      generate(Domain, ctx)
      migrate(ctx)
      assert index_sql("items") == before
    end
  end

  describe "opting in through the repo's config" do
    @tag repo_config: [rebuild_tables: true]
    test "the repo's config turns it on for every run", %{ctx: ctx} do
      domain = make_name_optional_from_required(ctx)

      generate(domain, ctx, rebuild_tables: nil)

      assert last_migration(ctx) =~ "rebuild_table :items"
    end

    @tag repo_config: [rebuild_tables: true]
    test "--no-rebuild-tables turns it off for one run", %{ctx: ctx} do
      domain = make_name_optional_from_required(ctx)

      generate(domain, ctx, rebuild_tables: false)

      migration = last_migration(ctx)
      refute migration =~ "rebuild_table"
      assert migration =~ "modify :name, :text, null: true"
    end

    defp make_name_optional_from_required(ctx) do
      defitem do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, allow_nil?: false)
        end
      end

      generate(Domain, ctx, rebuild_tables: nil)

      defitem do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string)
        end
      end

      # the alias made by `defdomain` only lives in this function
      Domain
    end
  end
end
