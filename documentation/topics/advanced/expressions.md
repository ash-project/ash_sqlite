# Expressions

In addition to the expressions listed in the [Ash expressions guide](https://hexdocs.pm/ash/expressions.html), AshSqlite provides the following expressions

# Fragments

Fragments allow you to use arbitrary sqlite expressions in your queries. Fragments can often be an escape hatch to allow you to do things that don't have something officially supported with Ash.

### Examples

#### Simple expressions

```elixir
fragment("? / ?", points, count)
```

#### Calling functions

```elixir
fragment("repeat('hello', 4)")
```

#### Using entire queries

```elixir
fragment("points > (SELECT SUM(points) FROM games WHERE user_id = ? AND id != ?)", user_id, id)
```

> ### a last resport {: .warning}
>
> Using entire queries as shown above is a last resort, but can sometimes be the best way to accomplish a given task.

#### In calculations

```elixir
calculations do
  calculate :lower_name, :string, expr(
    fragment("LOWER(?)", name)
  )
end
```

#### In migrations

```elixir
create table(:managers, primary_key: false) do
  add :id, :uuid, null: false, default: fragment("UUID_GENERATE_V4()"), primary_key: true
end
```

## Like

These wrap the sqlite builtin like operator

Please be aware, these match _patterns_ not raw text. Use `contains/1` if you want to match text without supporting patterns, i.e `%` and `_` have semantic meaning!

For example:

```elixir
Ash.Query.filter(User, like(name, "%obo%")) # name contains obo anywhere in the string, case sensitively
```
