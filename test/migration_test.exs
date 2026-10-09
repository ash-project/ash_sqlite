# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MigrationTest do
  @moduledoc """
  Runs migrations that use `AshSqlite.Migration` on a real SQLite file.
  """
  use ExUnit.Case, async: false
  @moduletag :migration
  @moduletag :tmp_dir

  import AshSqlite.RebuildHelper

  setup %{tmp_dir: tmp_dir} = context do
    repo = Map.get(context, :repo, AshSqlite.RebuildTestRepo)
    %{ctx: start(tmp_dir, Map.get(context, :repo_config, []), repo)}
  end

  # posts, and comments that are deleted with their post, with a row each
  defp blog(ctx) do
    write_migration(ctx, 1, "create_blog", """
    def up do
      create table(:posts, primary_key: false) do
        add :id, :text, primary_key: true
        add :title, :text, null: false
        add :subtitle, :text
      end

      create table(:comments, primary_key: false) do
        add :id, :text, primary_key: true
        add :post_id, references(:posts, type: :text, on_delete: :delete_all)
      end
    end

    def down do
      drop table(:comments)
      drop table(:posts)
    end
    """)

    migrate(ctx)
    sql("INSERT INTO posts (id, title) VALUES ('p', 'hello')")
    sql("INSERT INTO comments (id, post_id) VALUES ('c', 'p')")
  end

  @tag repo_config: [pool_size: 1]
  test "rebuilds a table: its rows stay, and so do the rows that point at it", %{ctx: ctx} do
    blog(ctx)

    write_migration(ctx, 2, "subtitle_required", """
    def up do
      rebuild_table :posts do
        add :id, :text, primary_key: true
        add :title, :text
        add :subtitle, :text
      end
    end

    def down, do: :ok
    """)

    migrate(ctx)

    assert [%{name: "title", notnull: false}] =
             Enum.filter(columns("posts"), &(&1.name == "title"))

    assert sql("SELECT id, title FROM posts") == [["p", "hello"]]
    # dropping the old table did not run ON DELETE CASCADE on the comments
    assert sql("SELECT id FROM comments") == [["c"]]
    assert sql("PRAGMA foreign_keys") == [[1]]
  end

  test "copy: renames a column and computes a value", %{ctx: ctx} do
    blog(ctx)

    write_migration(ctx, 2, "rename_and_slug", """
    def up do
      rebuild_table :posts, copy: [name: :title, slug: "lower(title) || '!'"] do
        add :id, :text, primary_key: true
        add :name, :text
        add :slug, :text
      end
    end

    def down, do: :ok
    """)

    migrate(ctx)

    assert sql("SELECT id, name, slug FROM posts") == [["p", "hello", "hello!"]]
  end

  test "a copy: that names a column the new table does not have says so", %{ctx: ctx} do
    blog(ctx)

    write_migration(ctx, 2, "typo", """
    def up do
      rebuild_table :posts, copy: [nme: "'x'"] do
        add :id, :text, primary_key: true
        add :name, :text
      end
    end

    def down, do: :ok
    """)

    error = migrate_error(ctx)
    assert error =~ "names nme, which the new table does not have"
    assert error =~ "it has id, name"
  end

  test "a rebuild that would copy nothing refuses, rather than lose the rows", %{ctx: ctx} do
    write_migration(ctx, 1, "create_items", """
    def up do
      execute "CREATE TABLE items (old TEXT)"
      execute "INSERT INTO items VALUES ('a'), ('b')"
    end

    def down, do: :ok
    """)

    write_migration(ctx, 2, "replace_items", """
    def up do
      rebuild_table :items do
        add :new, :text, default: "new"
      end
    end

    def down, do: :ok
    """)

    assert migrate_error(ctx) =~ "would copy nothing"
    assert sql("SELECT old FROM items ORDER BY old") == [["a"], ["b"]]
    assert versions() == [1]
  end

  @tag repo_config: [pool_size: 1]
  test "when it fails, nothing is changed and foreign keys are back on", %{ctx: ctx} do
    blog(ctx)
    before = columns("posts")

    write_migration(ctx, 2, "subtitle_required", """
    def up do
      rebuild_table :posts do
        add :id, :text, primary_key: true
        add :title, :text, null: false
        add :subtitle, :text, null: false
      end
    end

    def down, do: :ok
    """)

    assert migrate_error(ctx) =~ "NOT NULL constraint failed"

    assert columns("posts") == before
    assert sql("SELECT id FROM comments") == [["c"]]
    assert leftovers() == []
    assert versions() == [1]
    assert sql("PRAGMA foreign_keys") == [[1]]
  end

  @tag repo_config: [pool_size: 1]
  test "a foreign key that is already violated stops it", %{ctx: ctx} do
    blog(ctx)
    sql("PRAGMA foreign_keys = OFF")
    sql("INSERT INTO comments (id, post_id) VALUES ('orphan', 'nobody')")

    write_migration(ctx, 2, "anything", """
    def up do
      rebuild_table :posts do
        add :id, :text, primary_key: true
        add :title, :text
        add :subtitle, :text
      end
    end

    def down, do: :ok
    """)

    assert migrate_error(ctx) =~ "foreign key check failed"
    assert versions() == [1]
    assert leftovers() == []
  end

  test "a migration without a transaction refuses, rather than drop with foreign keys on", %{
    ctx: ctx
  } do
    blog(ctx)

    write_migration(ctx, 2, "no_transaction", """
    @disable_ddl_transaction true

    def up do
      rebuild_table :posts do
        add :id, :text, primary_key: true
        add :title, :text
        add :subtitle, :text
      end
    end

    def down, do: :ok
    """)

    assert migrate_error(ctx) =~ "refusing to rebuild posts: foreign keys are on"
    assert sql("SELECT id FROM comments") == [["c"]]
  end

  describe "with ecto_libsql" do
    @describetag repo: AshSqlite.RebuildLibSqlRepo

    # it has no `foreign_keys:` connection option, so what the migration does to the PRAGMA is
    # all there is: a rebuild that left them on would have deleted the comments
    @tag repo_config: [pool_size: 1]
    test "a rebuild keeps the rows that point at the table", %{ctx: ctx} do
      blog(ctx)

      write_migration(ctx, 2, "title_optional", """
      def up do
        rebuild_table :posts do
          add :id, :text, primary_key: true
          add :title, :text
          add :subtitle, :text
        end
      end

      def down, do: :ok
      """)

      migrate(ctx)

      assert sql("SELECT id FROM comments") == [["c"]]
      assert sql("PRAGMA foreign_keys") == [[1]]
    end
  end
end
