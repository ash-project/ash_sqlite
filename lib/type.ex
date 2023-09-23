defmodule AshSqlite.Type do
  @moduledoc """
  Sqlite specific callbacks for `Ash.Type`.

  Use this in addition to `Ash.Type`.
  """

  @callback value_to_sqlite_default(Ash.Type.t(), Ash.Type.constraints(), term) ::
              {:ok, String.t()} | :error

  defmacro __using__(_) do
    quote do
      @behaviour AshSqlite.Type
      def value_to_sqlite_default(_, _, _), do: :error

      defoverridable value_to_sqlite_default: 3
    end
  end
end
