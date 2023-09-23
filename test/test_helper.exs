ExUnit.start()
ExUnit.configure(stacktrace_depth: 100)

AshSqlite.TestRepo.start_link()
AshSqlite.TestNoSandboxRepo.start_link()
