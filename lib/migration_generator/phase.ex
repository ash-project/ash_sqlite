defmodule AshSqlite.MigrationGenerator.Phase do
  @moduledoc false

  defmodule Create do
    @moduledoc false
    defstruct [:table, :multitenancy, operations: [], commented?: false]

    import AshSqlite.MigrationGenerator.Operation.Helper, only: [as_atom: 1]

    def up(%{table: table, operations: operations}) do
      opts = ""

      "create table(:#{as_atom(table)}, primary_key: false#{opts}) do\n" <>
        Enum.map_join(operations, "\n", fn operation -> operation.__struct__.up(operation) end) <>
        "\nend"
    end

    def down(%{table: table}) do
      opts = ""

      "drop table(:#{as_atom(table)}#{opts})"
    end
  end

  defmodule Alter do
    @moduledoc false
    defstruct [:table, :multitenancy, operations: [], commented?: false]

    import AshSqlite.MigrationGenerator.Operation.Helper, only: [as_atom: 1]

    def up(%{table: table, operations: operations}) do
      body =
        operations
        |> Enum.map_join("\n", fn operation -> operation.__struct__.up(operation) end)
        |> String.trim()

      if body == "" do
        ""
      else
        opts = ""

        "alter table(:#{as_atom(table)}#{opts}) do\n" <>
          body <>
          "\nend"
      end
    end

    def down(%{table: table, operations: operations}) do
      body =
        operations
        |> Enum.reverse()
        |> Enum.map_join("\n", fn operation -> operation.__struct__.down(operation) end)
        |> String.trim()

      if body == "" do
        ""
      else
        opts = ""

        "alter table(:#{as_atom(table)}#{opts}) do\n" <>
          body <>
          "\nend"
      end
    end
  end
end
