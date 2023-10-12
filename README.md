# AshSqlite

![Elixir CI](https://github.com/ash-project/ash_sqlite/workflows/Elixir%20CI/badge.svg)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Coverage Status](https://coveralls.io/repos/github/ash-project/ash_sqlite/badge.svg?branch=main)](https://coveralls.io/github/ash-project/ash_sqlite?branch=main)
[![Hex version badge](https://img.shields.io/hexpm/v/ash_sqlite.svg)](https://hex.pm/packages/ash_sqlite)

## Notice: Beta

This is a newly released library. You can expect some hiccups here and there. Please report any issues you find!

## DSL

See the DSL documentation in `AshSqlite.DataLayer` for DSL documentation

## Usage

Add `ash_qlite` to your `mix.exs` file.

```elixir
{:ash_sqlite, "~> 0.1.1"}
```

To use this data layer, you need to chage your Ecto Repo's from `use Ecto.Repo`, to `use Sqlite.Repo`. because AshSqlite adds functionality to Ecto Repos.

Then, configure each of your `Ash.Resource` resources by adding `use Ash.Resource, data_layer: AshSqlite.DataLayer` like so:

```elixir
defmodule MyApp.SomeResource do
  use Ash.Resource, data_layer: AshSqlite.DataLayer

  sqlite do
    repo MyApp.Repo
    table "table_name"
  end

  attributes do
    # ... Attribute definitions
  end
end
```

## Generating Migrations

See the documentation for `Mix.Tasks.AshSqlite.GenerateMigrations` for how to generate migrations from your resources

# Contributors

Ash is made possible by its excellent community!

<a href="https://github.com/ash-project/ash_sqlite/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=ash-project/ash_sqlite" />
</a>

[Become a contributor](https://ash-hq.org/docs/guides/ash/latest/how_to/contribute.md)
