ExUnit.start()
ExUnit.configure(stacktrace_depth: 100)

AshSqlite.TestRepo.start_link()

Ecto.Adapters.SQL.Sandbox.mode(AshSqlite.TestRepo, :manual)
