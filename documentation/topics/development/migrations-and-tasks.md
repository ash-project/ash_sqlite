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
