# SPDX-FileCopyrightText: 2020 Zach Daniel
#
# SPDX-License-Identifier: MIT

ExUnit.start()
ExUnit.configure(stacktrace_depth: 100)

AshSqlite.TestRepo.start_link()
AshSqlite.DevTestRepo.start_link()

Ecto.Adapters.SQL.Sandbox.mode(AshSqlite.TestRepo, :manual)
Ecto.Adapters.SQL.Sandbox.mode(AshSqlite.DevTestRepo, :manual)
