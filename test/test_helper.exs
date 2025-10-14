# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs.contributors>
#
# SPDX-License-Identifier: MIT

ExUnit.start()
ExUnit.configure(stacktrace_depth: 100)

AshSqlite.TestRepo.start_link()
AshSqlite.DevTestRepo.start_link()

Ecto.Adapters.SQL.Sandbox.mode(AshSqlite.TestRepo, :manual)
Ecto.Adapters.SQL.Sandbox.mode(AshSqlite.DevTestRepo, :manual)
