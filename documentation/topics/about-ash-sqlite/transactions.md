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

## Enabling Transactions

Transactions are opt in per resource, via `write_transactions?` in the `sqlite`
block:

```elixir
sqlite do
  table "accounts"
  repo MyApp.Repo
  write_transactions? true
end
```

Turning this on is worth it wherever an action does more than one thing. Without
a transaction, a create whose `after_action` hook fails leaves its record behind:
the insert already committed on its own, and there is nothing to undo it. With
one, the failure rolls the insert back.

Ash derives `transaction? true` on create, update and destroy actions, and then
clears it again on a resource whose data layer cannot transact. So on a resource
that has not opted in, `Ash.Resource.Info.action(MyApp.Post, :create).transaction?`
reads `false` and says what will really happen, rather than naming a transaction
the data layer was never going to open. Turning `write_transactions?` on is what
lets that default stand.

Read it as a statement about the *repo*, not just the resource — a resource only
transacts safely once the repo underneath it is configured as below. Leaving it
off is not a bug, and it stays the default so that existing applications are
unaffected.

> ### Transactions are opened as IMMEDIATE {: .info}
>
> When a write transaction is opened, AshSqlite issues `BEGIN IMMEDIATE` rather
> than letting it default to deferred, whatever `default_transaction_mode` is set
> to. This is what makes `busy_timeout` effective for transactions that read
> before they write.
>
> A deferred transaction takes no lock until its first write, so a
> read-then-write has to *upgrade* to the write lock partway through. SQLite
> cannot make an upgrade wait: the snapshot the transaction already read from may
> be stale by the time the lock frees, so it fails immediately no matter how long
> `busy_timeout` is. `BEGIN IMMEDIATE` takes the lock up front, and has nothing to
> upgrade.
>
> Read-only transactions stay deferred, since they never take the write lock.

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
