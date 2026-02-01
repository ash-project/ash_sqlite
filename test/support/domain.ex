# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

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
    resource(AshSqlite.Test.Device)
  end

  authorization do
    authorize(:when_requested)
  end
end
