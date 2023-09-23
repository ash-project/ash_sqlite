# Sqlite Expressions

In addition to the expressions listed in the [Ash expressions guide](https://hexdocs.pm/ash/expressions.html), AshSqlite provides the following expressions

## Fragments
`fragment` allows you to embed raw sql into the query. Use question marks to interpolate values from the outer expression.

For example:

```elixir
Ash.Query.filter(User, fragment("? IS NOT NULL", first_name))
```

# Like

This wraps the builtin sqlite `LIKE` operator.

Please be aware, these match *patterns* not raw text. Use `contains/1` if you want to match text without supporting patterns, i.e `%` and `_` have semantic meaning!

For example:

```elixir
Ash.Query.filter(User, like(name, "%obo%")) # name contains obo anywhere in the string, case sensitively
```
