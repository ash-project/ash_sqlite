defmodule AshSqlite.Test.Api do
  @moduledoc false
  use Ash.Api

  resources do
    registry(AshSqlite.Test.Registry)
  end
end
