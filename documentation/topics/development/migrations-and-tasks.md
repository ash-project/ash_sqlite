<!--
SPDX-FileCopyrightText: 2020 Zach Daniel

SPDX-License-Identifier: MIT
-->

# Migrations

## Tasks

Ash comes with its own tasks, and AshSqlite exposes lower level tasks that you can use if necessary. This guide shows the process using `ash.*` tasks, and the `ash_sqlite.*` tasks are illustrated at the bottom.

## Basic Workflow

### Development Workflow (Recommended)

For development iterations, use the dev workflow to avoid naming migrations prematurely:

1. Make resource changes
2. Run `mix ash.codegen --dev` to generate dev migrations
3. Review the migrations and run `mix ash.migrate` to run them
4. Continue making changes and running `mix ash.codegen --dev` as needed
5. When your feature is complete, run `mix ash.codegen add_feature_name` to generate final named migrations (this will remove dev migrations and squash them)
6. Review the migrations and run `mix ash.migrate` to run them

### Traditional Migration Generation

For single-step changes or when you know the final feature name:

1. Make resource changes
2. Run `mix ash.codegen --name add_a_combobulator` to generate migrations and resource snapshots
3. Run `mix ash.migrate` to run those migrations

> **Tip**: The dev workflow (`--dev` flag) is preferred during development as it allows you to iterate without thinking of migration names and provides better development ergonomics.

> **Warning**: Always review migrations before applying them to ensure they are correct and safe.

For more information on generating migrations, run `mix help ash_sqlite.generate_migrations` (the underlying task that is called by `mix ash.codegen`)

### Changes SQLite cannot make in place

SQLite can mostly add, rename and drop a column in place. Changing a column's type or default, adding or dropping a foreign key, changing a primary key and, as the adapters write it, making a column required or optional all need the table to be created again in its new shape, with the rows copied over.

By default the generator writes a statement that fails when the migration runs. With `--rebuild-tables`, or `rebuild_tables: true` in the repo's config, it writes a `rebuild_table` instead, which shows the table's new shape and what triggered it:

```elixir
def up do
  # SQLite cannot change `comments` in place, so it is rebuilt from the resource's
  # snapshot. Anything on the table that the resource does not describe (a column,
  # index or trigger added by hand) is not kept. Changes:
  # - dropping the foreign key comments_post_id_fkey
  rebuild_table :comments do
    add :id, :uuid, null: false, primary_key: true
    add :post_id, :uuid
  end
end
```

The rebuild runs in one transaction with foreign keys off, and changes nothing if it fails.

The custom statements of the resource are dropped (their `down`) before the rebuild and recreated (their `up`) after it, so what they hold is lost. To keep it, add the copy to the generated migration, around the statement's `execute` lines. For a statement that creates a table:

```elixir
custom_statements do
  statement :items_history do
    up "CREATE TABLE items_history (item_id TEXT)"
    down "DROP TABLE items_history"
  end
end
```

the generated migration drops and recreates `items_history` around the rebuild of `items`. The two lines marked `# added` keep the rows:

```elixir
def up do
  # SQLite cannot change `items` in place, so it is rebuilt ... Changes:
  # - modify :name, :text, null: true
  # - REVIEW: the custom statements :items_history are dropped (their `down`) before and ...
  execute("CREATE TABLE items_history_backup AS SELECT * FROM items_history")  # added

  execute("""
  DROP TABLE items_history
  """)

  rebuild_table :items do
    add :id, :uuid, null: false, primary_key: true
    add :name, :text
  end

  execute("""
  CREATE TABLE items_history (item_id TEXT)
  """)

  execute("INSERT INTO items_history SELECT * FROM items_history_backup")  # added
  execute("DROP TABLE items_history_backup")  # added
end
```

A full-text index needs no backup: it is rebuilt from its table by a command after the statement's `up`.

```elixir
statement :items_fts do
  up "CREATE VIRTUAL TABLE items_fts USING fts5(name, content='items', content_rowid='rowid')"
  down "DROP TABLE items_fts"
end
```

```elixir
def up do
  # SQLite cannot change `items` in place, so it is rebuilt ... Changes:
  # ...
  execute("""
  DROP TABLE items_fts
  """)

  rebuild_table :items do
    add :id, :uuid, null: false, primary_key: true
    add :name, :text
  end

  execute("""
  CREATE VIRTUAL TABLE items_fts USING fts5(name, content='items', content_rowid='rowid')
  """)

  execute("INSERT INTO items_fts(items_fts) VALUES('rebuild')")  # added
end
```

### Regenerating Migrations

Often, you will run into a situation where you want to make a slight change to a resource after you've already generated and run migrations. If you are using git and would like to undo those changes, then regenerate the migrations, this script may prove useful:

```bash
#!/bin/bash

# Get count of untracked migrations
N_MIGRATIONS=$(git ls-files --others priv/repo/migrations | wc -l)

# Rollback untracked migrations
mix ash_sqlite.rollback -n $N_MIGRATIONS

# Delete untracked migrations and snapshots
git ls-files --others priv/repo/migrations | xargs rm
git ls-files --others priv/resource_snapshots | xargs rm

# Regenerate migrations
mix ash.codegen --name $1

# Run migrations if flag
if echo $* | grep -e "-m" -q
then
  mix ash.migrate
fi
```

After saving this file to something like `regen.sh`, make it executable with `chmod +x regen.sh`. Now you can run it with `./regen.sh name_of_operation`. If you would like the migrations to automatically run after regeneration, add the `-m` flag: `./regen.sh name_of_operation -m`.

## Multiple Repos

If you are using multiple repos, you will likely need to use `mix ecto.migrate` and manage it separately for each repo, as the options would
be applied to both repo, which wouldn't make sense.

## Running Migrations in Production

Define a module similar to the following:

```elixir
defmodule MyApp.Release do
  @moduledoc """
  Houses tasks that need to be executed in the released application (because mix is not present in releases).
  """
  @app :my_ap
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    domains()
    |> Enum.flat_map(fn domain ->
      domain
      |> Ash.Domain.Info.resources()
      |> Enum.map(&AshSqlite.repo/1)
    end)
    |> Enum.uniq()
  end

  defp domains do
    Application.fetch_env!(:my_app, :ash_domains)
  end

  defp load_app do
    Application.load(@app)
  end
end
```

# AshSqlite-specific tasks

- `mix ash_sqlite.generate_migrations`
- `mix ash_sqlite.create`
- `mix ash_sqlite.migrate`
- `mix ash_sqlite.rollback`
- `mix ash_sqlite.drop`
