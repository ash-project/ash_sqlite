# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

ExUnit.start()
ExUnit.configure(stacktrace_depth: 100)

# A rebuild needs the migration callbacks of an `ecto_sql` that has them
if AshSqlite.Migration.rebuild_supported?() do
  ExUnit.configure(exclude: [:no_rebuild_support])
else
  ExUnit.configure(exclude: [:rebuild])
end

AshSqlite.TestRepo.start_link()
AshSqlite.TransactionTestRepo.start_link()
AshSqlite.DevTestRepo.start_link()

Ecto.Adapters.SQL.Sandbox.mode(AshSqlite.TestRepo, :manual)
Ecto.Adapters.SQL.Sandbox.mode(AshSqlite.TransactionTestRepo, :manual)
Ecto.Adapters.SQL.Sandbox.mode(AshSqlite.DevTestRepo, :manual)
