<!--
SPDX-FileCopyrightText: 2020 Zach Daniel

SPDX-License-Identifier: MIT
-->

# Transactions

## SQLite's Write Lock Limitation

SQLite allows only one write lock at a time. Any attempt to write while another
transaction already holds the write lock will immediately fail—there is no waiting
or queuing built in. This is fundamentally different from PostgreSQL, where
conflicting transactions queue up and proceed in order.

Because of this, **AshSqlite disables transaction support by default**
(`can?(:transact)` returns `false`). Without extra configuration, Ash will not
wrap actions in transactions when using the SQLite data layer.

## Enabling Reliable Concurrent Writes

`ecto_sqlite3` exposes two knobs that together make concurrent writes behave more
like you would expect:

- **`default_transaction_mode: :immediate`** — SQLite acquires the exclusive
  write lock at the *start* of each transaction instead of at the first write
  statement. This prevents the scenario where two transactions both start in
  deferred mode, both read successfully, and then race to upgrade to a write lock,
  causing one to fail.

- **`busy_timeout`** — SQLite will retry acquiring the write lock for up to this
  many milliseconds before returning an error. Set this to a non-zero value so
  that a brief contention window does not immediately surface as an error to your
  users.

Example repo configuration:

```elixir
# config/config.exs
config :my_app, MyApp.Repo,
  database: "path/to/my_app.db",
  pool_size: 1,
  default_transaction_mode: :immediate,
  busy_timeout: 5000
```

> ### Keep pool_size: 1 for writes {: .warning}
>
> SQLite does not support parallel writes, so a write pool larger than 1 will only
> cause contention. Set `pool_size: 1` on any repo that performs writes.

## Separate Read and Write Repos

For applications that need read concurrency, you can configure a dedicated
read-only repo alongside a write repo. The write repo uses `pool_size: 1` and
immediate transactions; the read repo opens multiple read-only connections.

```elixir
# config/config.exs
config :my_app, MyApp.Repo,
  database: "path/to/my_app.db",
  pool_size: 1,
  default_transaction_mode: :immediate,
  busy_timeout: 5000

config :my_app, MyApp.Repo.ReadOnly,
  database: "path/to/my_app.db",
  pool_size: 10,
  read_only: true
```

```elixir
# lib/my_app/repo.ex
defmodule MyApp.Repo do
  use AshSqlite.Repo, otp_app: :my_app
end

defmodule MyApp.Repo.ReadOnly do
  use AshSqlite.Repo, otp_app: :my_app
end
```

Start both repos in your application supervision tree:

```elixir
# lib/my_app/application.ex
children = [
  MyApp.Repo,
  MyApp.Repo.ReadOnly,
  ...
]
```

Then route reads and writes to the appropriate repo using a function in the
`repo` DSL option:

```elixir
sqlite do
  repo fn _resource, type ->
    case type do
      :mutate -> MyApp.Repo
      :read -> MyApp.Repo.ReadOnly
    end
  end
  table "posts"
end
```

The function receives the resource module and either `:read` or `:mutate` as
arguments and must return a repo module.
