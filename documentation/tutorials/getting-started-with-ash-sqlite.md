# Getting Started With AshSqlite

## Goals

In this guide we will:

1. Setup AshSqlite, which includes setting up [Ecto](https://hexdocs.pm/ecto/Ecto.html)
2. Add AshSqlite to the resources created in [the Ash getting started guide](https://hexdocs.pm/ash/get-started.html)
3. Show how the various features of AshSqlite can help you work quickly and cleanly against a sqlite database
4. Highlight some of the more advanced features you can use when using AshSqlite.
5. Point you to additional resources you may need on your journey

## Requirements

- A working SQLite installation, with a sufficiently permissive user
- If you would like to follow along, you will need to add begin with [the Ash getting started guide](https://hexdocs.pm/ash/get-started.html)

## Steps

### Add AshSqlite

Add the `:ash_sqlite` dependency to your application

`{:ash_sqlite, "~> 0.1.2-rc.1"}`

Add `:ash_sqlite` to your `.formatter.exs` file

```elixir
[
  # import the formatter rules from `:ash_sqlite`
  import_deps: [..., :ash_sqlite],
  inputs: [...]
]
```

### Create and configure your Repo

Create `lib/helpdesk/repo.ex` with the following contents. `AshSqlite.Repo` is a thin wrapper around `Ecto.Repo`, so see their documentation for how to use it if you need to use it directly. For standard Ash usage, all you will need to do is configure your resources to use your repo.

```elixir
# in lib/helpdesk/repo.ex

defmodule Helpdesk.Repo do
  use AshSqlite.Repo, otp_app: :helpdesk
end
```

Next we will need to create configuration files for various environments. Run the following to create the configuration files we need.

```bash
mkdir -p config
touch config/config.exs
touch config/dev.exs
touch config/runtime.exs
touch config/test.exs
```

Place the following contents in those files, ensuring that the credentials match the user you created for your database. For most conventional installations this will work out of the box. If you've followed other guides before this one, they may have had you create these files already, so just make sure these contents are there.

```elixir
# in config/config.exs
import Config

# This should already have been added in the first
# getting started guide
config :helpdesk,
  ash_apis: [Helpdesk.Support]

config :helpdesk,
  ecto_repos: [Helpdesk.Repo]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
```

```elixir
# in config/dev.exs

import Config

# Configure your database
config :helpdesk, Helpdesk.Repo,
  database: Path.join(__DIR__, "../path/to/your.db"),
  port: 5432,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10
```

```elixir
# in config/runtime.exs

import Config

if config_env() == :prod do
  config :helpdesk, Helpdesk.Repo,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")
end
```

```elixir
# in config/test.exs

import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :helpdesk, Helpdesk.Repo,
  database: Path.join(__DIR__, "../path/to/your#{System.get_env("MIX_TEST_PARTITION")}.db"),
  pool_size: 10
```

And finally, add the repo to your application

```elixir
# in lib/helpdesk/application.ex

  def start(_type, _args) do
    children = [
      # Starts a worker by calling: Helpdesk.Worker.start_link(arg)
      # {Helpdesk.Worker, arg}
      Helpdesk.Repo
    ]

    ...
```

### Add AshSqlite to our resources

Now we can add the data layer to our resources. The basic configuration for a resource requires the `d:AshSqlite.sqlite|table` and the `d:AshSqlite.sqlite|repo`.

```elixir
# in lib/helpdesk/support/resources/ticket.ex

  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "tickets"
    repo Helpdesk.Repo
  end
```

```elixir
# in lib/helpdesk/support/resources/representative.ex

  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "representatives"
    repo Helpdesk.Repo
  end
```

### Create the database and tables

First, we'll create the database with `mix ash_sqlite.create`.

Then we will generate database migrations. This is one of the many ways that AshSqlite can save time and reduce complexity.

```bash
mix ash_sqlite.generate_migrations --name add_tickets_and_representatives
```

If you are unfamiliar with database migrations, it is a good idea to get a rough idea of what they are and how they work. See the links at the bottom of this guide for more. A rough overview of how migrations work is that each time you need to make changes to your database, they are saved as small, reproducible scripts that can be applied in order. This is necessary both for clean deploys as well as working with multiple developers making changes to the structure of a single database.

Typically, you need to write these by hand. AshSqlite, however, will store snapshots each time you run the command to generate migrations and will figure out what migrations need to be created.

You should always look at the generated migrations to ensure that they look correct. Do so now by looking at the generated file in `priv/repo/migrations`.

Finally, we will create the local database and apply the generated migrations:

```bash
mix ash_sqlite.create
mix ash_sqlite.migrate
```

### Try it out

And now we're ready to try it out! Run the following in iex:

Lets create some data. We'll make a representative and give them some open and some closed tickets.

```elixir
require Ash.Query

representative = (
  Helpdesk.Support.Representative
  |> Ash.Changeset.for_create(:create, %{name: "Joe Armstrong"})
  |> Helpdesk.Support.create!()
)

for i <- 0..5 do
  ticket =
    Helpdesk.Support.Ticket
    |> Ash.Changeset.for_create(:open, %{subject: "Issue #{i}"})
    |> Helpdesk.Support.create!()
    |> Ash.Changeset.for_update(:assign, %{representative_id: representative.id})
    |> Helpdesk.Support.update!()

  if rem(i, 2) == 0 do
    ticket
    |> Ash.Changeset.for_update(:close)
    |> Helpdesk.Support.update!()
  end
end
```

And now we can read that data. You should see some debug logs that show the sql queries AshSqlite is generating.

```elixir
require Ash.Query

# Show the tickets where the subject equals "foobar"
Helpdesk.Support.Ticket
|> Ash.Query.filter(subject == "foobar")
|> Helpdesk.Support.read!()
```

```elixir
require Ash.Query

# Show the tickets that are closed and their subject does not equal "barbaz"
Helpdesk.Support.Ticket
|> Ash.Query.filter(status == :closed and not(subject == "barbaz"))
|> Helpdesk.Support.read!()
```

And, naturally, now that we are storing this in sqlite, this database is persisted even if we stop/start our application. The nice thing, however, is that this was the _exact_ same code that we ran against our resources when they were backed by ETS.

### Calculations

Calculations can be pushed down into SQL using expressions.

For example, we can determine the percentage of tickets that are open:

```elixir
# in lib/helpdesk/support/resources/representative.ex

  calculations do
    calculate :percent_open, :float, expr(open_tickets / total_tickets )
  end
```

Calculations can be loaded.

```elixir
require Ash.Query

Helpdesk.Support.Representative
|> Ash.Query.filter(percent_open > 0.25)
|> Ash.Query.sort(:percent_open)
|> Ash.Query.load(:percent_open)
|> Helpdesk.Support.read!()
```

### Rich Configuration Options

Take a look at the DSL documentation for more information on what you can configure. You can add check constraints, configure the behavior of foreign keys and more!

### Deployment

When deploying, you will need to ensure that the file you are using in production is persisted in some way (probably, unless you want it to disappear whenever your deployed system restarts). For example with fly.io this might mean adding a volume to your deployment.

### What next?

- Check out the data layer docs: `AshSqlite.DataLayer`

- [Ecto's documentation](https://hexdocs.pm/ecto/Ecto.html). AshSqlite (and much of Ash itself) is made possible by the amazing Ecto. If you find yourself looking for escape hatches when using Ash or ways to work directly with your database, you will want to know how Ecto works. Ash and AshSqlite intentionally do not hide Ecto, and in fact encourages its use whenever you need an escape hatch.

- [Ecto's Migration documentation](https://hexdocs.pm/ecto_sql/Ecto.Migration.html) read more about migrations. Even with the ash_sqlite migration generator, you will very likely need to modify your own migrations some day.
