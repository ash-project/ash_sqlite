# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.RebuildUnsupportedTest do
  @moduledoc """
  What a rebuild does on an `ecto_sql` without the migration callbacks: it refuses.
  """
  use ExUnit.Case, async: false
  @moduletag :no_rebuild_support
  @moduletag :tmp_dir

  import AshSqlite.RebuildHelper

  setup %{tmp_dir: tmp_dir}, do: %{ctx: start(tmp_dir)}

  test "a rebuild refuses while foreign keys are on, and the rows that point at the table stay",
       %{ctx: ctx} do
    write_migration(ctx, 1, "create_blog", """
    def up do
      create table(:posts, primary_key: false) do
        add :id, :text, primary_key: true
      end

      create table(:comments, primary_key: false) do
        add :id, :text, primary_key: true
        add :post_id, references(:posts, type: :text, on_delete: :delete_all)
      end
    end

    def down, do: :ok
    """)

    migrate(ctx)
    sql("INSERT INTO posts (id) VALUES ('p')")
    sql("INSERT INTO comments (id, post_id) VALUES ('c', 'p')")

    write_migration(ctx, 2, "rebuild_posts", """
    def up do
      rebuild_table :posts do
        add :id, :text, primary_key: true
        add :title, :text
      end
    end

    def down, do: :ok
    """)

    assert migrate_error(ctx) =~ "only in an `ecto_sql` that has them"
    assert sql("SELECT id FROM comments") == [["c"]]
    assert versions() == [1]
  end
end
