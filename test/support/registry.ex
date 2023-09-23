defmodule AshSqlite.Test.Registry do
  @moduledoc false
  use Ash.Registry

  entries do
    entry(AshSqlite.Test.Post)
    entry(AshSqlite.Test.Comment)
    entry(AshSqlite.Test.IntegerPost)
    entry(AshSqlite.Test.Rating)
    entry(AshSqlite.Test.PostLink)
    entry(AshSqlite.Test.PostView)
    entry(AshSqlite.Test.Author)
    entry(AshSqlite.Test.Profile)
    entry(AshSqlite.Test.User)
    entry(AshSqlite.Test.Account)
    entry(AshSqlite.Test.Organization)
    entry(AshSqlite.Test.Manager)
  end
end
