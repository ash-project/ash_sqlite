# Migrations

## Migration Generator Primer

<iframe width="560" height="315" src="https://www.youtube.com/embed/GtsL_lIis4Q?si=5G6-5ckzBEzL4zko" title="YouTube video player" frameborder="0" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" allowfullscreen></iframe>

## Tasks

The available tasks are:

- `mix ash_sqlite.generate_migrations`
- `mix ash_sqlite.create`
- `mix ash_sqlite.drop`

AshSqlite is built on top of ecto, so much of its behavior is pass-through/orchestration of that tooling.

## Basic Workflow

- Make resource changes
- Run `mix ash_sqlite.generate_migrations` to generate migrations and resource snapshots
- Run `mix ash_sqlite.migrate` to run those migrations

For more information on generating migrations, see the module documentation here:
`Mix.Tasks.AshSqlite.GenerateMigrations`, or run `mix help ash_sqlite.generate_migrations`

For running your migrations, there is a mix task that will find all of the repos configured in your apis and run their
migrations. It is a thin wrapper around `mix ecto.migrate`. Ours is called `mix ash_sqlite.migrate`

If you want to run or rollback individual migrations, use the corresponding

### Regenerating Migrations

Often, you will run into a situation where you want to make a slight change to a resource after you've already generated and run migrations. If you are using git and would like to undo those changes, then regenerate the migrations, this script may prove useful:

```bash
#!/bin/bash

# Get count of untracked migrations
N_MIGRATIONS=$(git ls-files --others priv/repo/migrations | wc -l)

# Rollback untracked migrations
mix ecto.rollback -n $N_MIGRATIONS

# Delete untracked migrations and snapshots
git ls-files --others priv/repo/migrations | xargs rm
git ls-files --others priv/resource_snapshots | xargs rm

# Regenerate migrations
mix ash_sqlite.generate_migrations

# Run migrations if flag
if echo $* | grep -e "-m" -q
then
  mix ecto.migrate
fi
```

After saving this file to something like `regen.sh`, make it executable with `chmod +x regen.sh`. Now you can run it with `./regen.sh`. If you would like the migrations to automatically run after regeneration, add the `-m` flag: `./regen.sh -m`.

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
    apis()
    |> Enum.flat_map(fn api ->
      api
      |> Ash.Api.Info.resources()
      |> Enum.map(&AshSqlite.repo/1)
    end)
    |> Enum.uniq()
  end

  defp apis do
    Application.fetch_env!(:my_app, :ash_apis)
  end

  defp load_app do
    Application.load(@app)
  end
end
```
