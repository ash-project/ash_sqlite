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
    repo = tags[:repo] || AshSqlite.TestRepo
    :ok = Sandbox.checkout(repo)

    unless tags[:async] do
      Sandbox.mode(repo, {:shared, self()})
    end

    :ok
  end
end
