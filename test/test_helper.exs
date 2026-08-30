# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

ExUnit.start()
ExUnit.configure(stacktrace_depth: 100)

AshSqlite.TestRepo.start_link()
AshSqlite.DevTestRepo.start_link()

# Named, so that a `global? true` resource on this module has an instance of its own
# to bind -- the shared database, as opposed to any tenant's.
AshSqlite.TenantRepo.start_link()

Ecto.Adapters.SQL.query!(
  AshSqlite.TenantRepo,
  "CREATE TABLE IF NOT EXISTS global_posts (id TEXT PRIMARY KEY, title TEXT)",
  []
)

Ecto.Adapters.SQL.Sandbox.mode(AshSqlite.TestRepo, :manual)
Ecto.Adapters.SQL.Sandbox.mode(AshSqlite.DevTestRepo, :manual)
