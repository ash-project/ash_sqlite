defmodule AshSqlite.RepoCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias AshSqlite.TestRepo

      import Ecto
      import Ecto.Query
      import AshSqlite.RepoCase

      # and any other stuff
    end
  end

  setup tags do
    :ok = Sandbox.checkout(AshSqlite.TestRepo)

    unless tags[:async] do
      Sandbox.mode(AshSqlite.TestRepo, {:shared, self()})
    end

    :ok
  end
end
