# What is AshSqlite?

AshSqlite is the SQLite `Ash.DataLayer` for [Ash Framework](https://hexdocs.pm/ash). This doesn't have all of the features of [AshPostgres](https://hexdocs.pm/ash_postgres), but it does support most of the features of Ash data layers. The main feature missing is Aggregate support.

Use this to persist records in a SQLite table. For example, the resource below would be persisted in a table called `tweets`:

```elixir
defmodule MyApp.Tweet do
  use Ash.Resource,
    data_layer: AshSQLite.DataLayer

  attributes do
    integer_primary_key :id
    attribute :text, :string
  end

  relationships do
    belongs_to :author, MyApp.User
  end

  sqlite do
    table "tweets"
    repo MyApp.Repo
  end
end
```

The table might look like this:

| id  | text            | author_id |
| --- | --------------- | --------- |
| 1   | "Hello, world!" | 1         |

Creating records would add to the table, destroying records would remove from the table, and updating records would update the table.
