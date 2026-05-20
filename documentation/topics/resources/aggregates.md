<!--
SPDX-FileCopyrightText: 2020 Zach Daniel

SPDX-License-Identifier: MIT
-->

# Aggregates

AshSqlite supports resource aggregates that can be loaded, filtered, sorted, and used in expression calculations. For general Ash aggregate usage, see the [Ash aggregates guide](https://hexdocs.pm/ash/aggregates.html).

## Supported Aggregates

AshSqlite supports related `count`, `sum`, `avg`, `min`, `max`, `exists`, `first`, `list`, and `custom` aggregates over normal relationship paths.

```elixir
aggregates do
  count :total_tickets, :tickets
  exists :has_open_tickets, :tickets do
    filter expr(status == :open)
  end

  first :first_ticket_subject, :tickets, :subject do
    sort subject: :asc_nils_last
  end

  list :ticket_subjects, :tickets, :subject do
    sort subject: :asc_nils_last
  end
end
```

Aggregates are translated to SQL and can be used in queries.

```elixir
require Ash.Query

Helpdesk.Support.Representative
|> Ash.Query.filter(total_tickets > 2)
|> Ash.Query.sort(total_tickets: :desc)
|> Ash.Query.load([:total_tickets, :first_ticket_subject])
|> Ash.read!()
```

Aggregates can also be loaded on records that have already been read.

```elixir
representatives = Helpdesk.Support.read!(Helpdesk.Support.Representative)

Ash.load!(representatives, [:total_tickets, :ticket_subjects])
```

## Calculations

Expression calculations can reference aggregates and be pushed down to SQLite.

```elixir
aggregates do
  count :total_tickets, :tickets

  count :open_tickets, :tickets do
    filter expr(status == :open)
  end
end

calculations do
  calculate :percent_open, :float, expr(open_tickets / total_tickets)
end
```

Calculations that reference aggregates can be loaded, filtered, and sorted in the same way.

```elixir
require Ash.Query

Helpdesk.Support.Representative
|> Ash.Query.filter(percent_open > 0.25)
|> Ash.Query.sort(:percent_open)
|> Ash.Query.load(:percent_open)
|> Ash.read!()
```

## Relationship Paths

Aggregates are supported over normal relationship paths, including multi-hop paths.

```elixir
aggregates do
  count :comment_count, [:posts, :comments]
  sum :paid_total, [:orders, :payments], :amount
end
```

One-hop many-to-many relationship aggregates are supported.

```elixir
aggregates do
  count :linked_post_count, :linked_posts

  first :first_linked_post_title, :linked_posts, :title do
    sort title: :asc_nils_last
  end
end
```

Parent-independent unrelated aggregates are supported when the aggregate query does not need values from the parent row.

```elixir
aggregates do
  count :published_post_count, Post do
    filter expr(published == true)
  end
end
```

## Aggregate Filters

Aggregate filters and aggregate `join_filter`s are supported for normal paths and one-hop many-to-many paths when they do not depend on parent row values.

```elixir
aggregates do
  count :open_ticket_count, :tickets do
    filter expr(status == :open)
  end

  count :matching_ticket_count, :tickets do
    join_filter :tickets, expr(priority == :high)
  end
end
```

## SQLite Requirements

`first` and `list` aggregates require SQLite 3.30.0 or later with JSON functions enabled. Window functions were added in SQLite 3.25.0, but AshSqlite's generated SQL also uses aggregate `FILTER` clauses and explicit `NULLS FIRST`/`NULLS LAST` ordering, which require SQLite 3.30.0 or later.

- window functions
- aggregate `FILTER`
- JSON aggregation
- explicit null ordering

JSON functions are built into SQLite by default as of SQLite 3.38.0. Older SQLite builds need the JSON1 extension enabled. Check the SQLite library used by your application, which may not be the same binary as the `sqlite3` command:

```elixir
MyApp.Repo.query!("select sqlite_version()")
MyApp.Repo.query!("select json_group_array(1)")
```

`list` aggregates return lists through SQLite JSON aggregation. `custom` aggregates require a SQLite-compatible aggregate expression or function.

## Custom Aggregates

Custom aggregates should use both `Ash.Resource.Aggregate.CustomAggregate` and `AshSqlite.CustomAggregate`.

```elixir
defmodule MyApp.StringAgg do
  use Ash.Resource.Aggregate.CustomAggregate
  use AshSqlite.CustomAggregate

  require Ecto.Query

  def dynamic(opts, binding) do
    Ecto.Query.dynamic(
      [],
      fragment("group_concat(?, ?)", field(as(^binding), ^opts[:field]), ^opts[:delimiter])
    )
  end
end
```

Then use that implementation from a resource aggregate.

```elixir
aggregates do
  custom :ticket_subjects_joined, :tickets, :string do
    implementation {MyApp.StringAgg, field: :subject, delimiter: ", "}
  end
end
```

`AshSqlite.CustomAggregate` only defines the `dynamic/2` contract. It does not install SQLite extensions or register user-defined functions. If your custom aggregate uses a function that is not built into SQLite, register it with the SQLite connection yourself and make sure it is available in every environment.

## Performance

AshSqlite builds aggregate queries as grouped subqueries or windowed subqueries and joins those results back to the parent query. Add indexes for the relationship keys used by those subqueries.

Useful indexes usually include:

- child foreign keys, like `tickets.representative_id`
- many-to-many join resource key pairs
- fields used by aggregate filters
- fields used by `first` and `list` aggregate sorts

## Unsupported Cases

Full aggregate parity with [AshPostgres](https://hexdocs.pm/ash_postgres) is not available. Unsupported cases include:

- inline query-level `list` and `custom` aggregate expressions
- unrelated aggregates that reference the parent row
- manual relationships
- `no_attributes?` relationships
- multi-hop paths that include many-to-many relationships
- parent-dependent relationship filters
- parent-dependent aggregate filters
- parent-dependent `join_filter`s
- aggregate filters that reference other aggregates
- expression sorts on `first` and `list` aggregates
- `uniq` list aggregates sorted by fields other than the listed field
- fanout-prone `sum`, `avg`, `list`, `custom`, or field-based `count` aggregate filters over to-many relationship references

A fanout-prone aggregate filter is one where filtering joins another to-many relationship and can duplicate the rows being aggregated. For example, a `sum` of comment likes filtered by `popular_ratings.id` could count the same comment once per matching rating. AshSqlite rejects these shapes instead of returning an over-counted result.
