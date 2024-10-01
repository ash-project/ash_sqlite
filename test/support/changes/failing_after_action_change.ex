defmodule AshSqlite.Test.FailingAfterActionChange do
  @moduledoc false
  use Ash.Resource.Change

  def change(changeset, _, _) do
    changeset
    |> Ash.Changeset.after_action(fn _changeset, _record ->
      {:error, "Things could always be better"}
    end)
  end
end
