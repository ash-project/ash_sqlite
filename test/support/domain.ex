defmodule AshSqlite.Test.Domain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource(AshSqlite.Test.Post)
    resource(AshSqlite.Test.Comment)
    resource(AshSqlite.Test.IntegerPost)
    resource(AshSqlite.Test.Rating)
    resource(AshSqlite.Test.PostLink)
    resource(AshSqlite.Test.PostView)
    resource(AshSqlite.Test.Author)
    resource(AshSqlite.Test.Profile)
    resource(AshSqlite.Test.User)
    resource(AshSqlite.Test.Account)
    resource(AshSqlite.Test.Organization)
    resource(AshSqlite.Test.Manager)
  end

  authorization do
    authorize(:when_requested)
  end
end
