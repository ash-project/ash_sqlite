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

Transactions are opt in, and they are configured on the **repo** rather than on
each resource:

```elixir
defmodule MyApp.Repo do
  use AshSqlite.Repo, otp_app: :my_app

  def write_transactions?, do: true
end
```

Every resource whose `sqlite` block names this repo may then have its write
actions wrapped in a transaction. It belongs on the repo because everything that
makes a transaction safe is repo configuration — the pool size, the busy timeout,
whether the connection is read only. There is no per-resource knob that changes
any of it, so a per-resource flag could only ever disagree with the connection it
runs on.

For a resource using a function repo, the `:mutate` repo is the one asked, so a
read-only repo never needs to answer. The function must be a capture of a named
function in another module:

```elixir
defmodule MyApp.Routing do
  def repo(_resource, :mutate), do: MyApp.Repo
  def repo(_resource, :read), do: MyApp.Repo.ReadOnly
end

sqlite do
  repo &MyApp.Routing.repo/2
end
```

An inline `fn` is refused. Spark compiles it into a function on the resource
itself, and the repo is asked whether it takes transactions while that module is
still compiling, so there is nothing to call yet.

Turning this on is worth it wherever an action does more than one thing. Without
a transaction, a create whose `after_action` hook fails leaves its record behind:
the insert already committed on its own, and there is nothing to undo it. With
one, the failure rolls the insert back.

To keep a particular action out of a transaction, set `transaction? false` on the
action. Ash will derive `transaction? true` on create, update and destroy actions
if the data layer supports transactions. On a repo that has not opted in
`Ash.Resource.Info.action(MyApp.Post, :create).transaction?` will be `false`.

> ### Transactions are opened as IMMEDIATE {: .info}
>
> When AshSqlite opens a transaction it issues `BEGIN IMMEDIATE`, regardless of what
> `default_transaction_mode` is set to. You do not need to configure that pragma
> for Ash's own transactions; it still applies to `Repo.transaction/2` calls you
> make yourself.
>
> A deferred transaction takes no lock until its first write, so a read-then-write
> has to *upgrade* to the write lock partway through. SQLite cannot make an upgrade
> wait: the snapshot the transaction already read from may be stale by the time the
> lock frees, so it fails immediately no matter how long `busy_timeout` is.
> `BEGIN IMMEDIATE` takes the lock up front, and has nothing to upgrade.

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

Two things worth adding to the above, now that Ash can open these transactions
itself:

- **Ash's own transactions do not need `default_transaction_mode`.** AshSqlite
  issues `BEGIN IMMEDIATE` for a write transaction whatever that setting says, so
  configuring it changes nothing for actions. Keep it for `Repo.transaction/2` calls
  you make directly.

- **`busy_timeout` needs an upper bound as well as a lower one.** It already
  defaults to `2000`. The driver's busy handler blocks the connection while it
  waits, so a value at or above the caller's `:timeout` (15s unless you change it)
  means the caller gives up first and the waiting bought nothing:

  ```
  longest competing lock hold  ≲  busy_timeout  <  :timeout
  ```

  Note also that at `pool_size: 1` a single node cannot contend with itself — one
  connection means two of your processes never hold the write lock at once, and
  contention surfaces as a checkout timeout rather than `SQLITE_BUSY`. What
  `busy_timeout` covers there is writers the pool cannot see: a second node,
  another OS process, or a `litestream` against the same file.

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

  def write_transactions?, do: true
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
arguments and must return a repo module. `write_transactions?` is read from the
`:mutate` repo, so the read-only repo never needs to declare it.
