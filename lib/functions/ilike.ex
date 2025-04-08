defmodule AshSqlite.Functions.ILike do
  @moduledoc """
  Maps to the builtin sqlite function `ilike`.
  """

  use Ash.Query.Function, name: :ilike, predicate?: true

  def args, do: [[:string, :string]]
end
