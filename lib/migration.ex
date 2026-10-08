# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Migration do
  @moduledoc """
  Helpers for migrations that rebuild a table.

  SQLite can mostly add, rename and drop columns in place. For most other changes it is
  [documented](https://www.sqlite.org/lang_altertable.html#otheralter) to create the table in
  its new shape, copy the rows, drop the old table and rename the new one:

      use AshSqlite.Migration

      def up do
        rebuild_table :posts do
          add :id, :uuid, null: false, primary_key: true
          add :title, :text
        end
      end

  `use AshSqlite.Migration` does what `use Ecto.Migration` does, and adds what makes a rebuild
  safe: foreign keys are off while it runs (dropping a table would otherwise run the `ON DELETE`
  actions of the tables that point to it) and they are checked before it commits. A rebuild
  either completes or changes nothing.
  """

  @pragmas_key :ash_sqlite_rebuild_pragmas

  @doc false
  defmacro __using__(_opts) do
    quote do
      use Ecto.Migration
      import AshSqlite.Migration, only: [rebuild_table: 2, rebuild_table: 3]

      defdelegate before_transaction(repo), to: AshSqlite.Migration, as: :__before_transaction__
      defdelegate after_transaction(repo), to: AshSqlite.Migration, as: :__after_transaction__

      def before_commit, do: AshSqlite.Migration.__check_foreign_keys__(repo())
    end
  end

  # `PRAGMA foreign_keys` does nothing inside a transaction, so it is set before Ecto opens one,
  # on the connection it will use. The previous values are kept to put them back afterwards.
  @doc false
  def __before_transaction__(repo) do
    Process.put(@pragmas_key, {pragma(repo, "foreign_keys"), pragma(repo, "legacy_alter_table")})
    quiet!(repo, "PRAGMA foreign_keys = OFF")
  end

  # `legacy_alter_table` is put back too: a rebuild that fails does not turn it off itself.
  @doc false
  def __after_transaction__(repo) do
    case Process.delete(@pragmas_key) do
      nil ->
        :ok

      {foreign_keys, legacy_alter_table} ->
        quiet!(repo, "PRAGMA legacy_alter_table = #{legacy_alter_table}")
        quiet!(repo, "PRAGMA foreign_keys = #{foreign_keys}")
    end
  end

  # Ecto does not run the callbacks for a migration without a transaction
  # (`@disable_ddl_transaction true`), and dropping a table with foreign keys on deletes
  # from the tables that reference it. So `rebuild_table/3` checks first that they are off.
  @doc false
  def __check_foreign_keys_off__(repo, table) do
    if pragma(repo, "foreign_keys") != 0 do
      raise "refusing to rebuild #{table}: foreign keys are on, so dropping it would run " <>
              "the ON DELETE actions of the tables that reference it. They are switched " <>
              "off by the callbacks `use AshSqlite.Migration` adds, which Ecto only runs " <>
              "when the migration runs in its own transaction: remove " <>
              "`@disable_ddl_transaction true`."
    end
  end

  @doc false
  def __legacy_alter_table__(repo, value),
    do: quiet!(repo, "PRAGMA legacy_alter_table = #{value}")

  @doc """
  Rebuilds `table` with the shape `block` describes, as the block of a `create table`.

  Every column the old and the new table both have is copied as it is. A column the
  old table did not have gets the `DEFAULT` of the new table.

  Options:

    * `:copy` - what to copy differently, as a keyword list from the new column to
      where its value comes from: `new: :old` copies the column `old` into `new` (a
      rename), and `new: "sql"` copies an SQL expression, which can look at the old
      table's columns (for example `COALESCE(name, 'unknown')` for a column that is
      becoming required, or `'unknown'` for a new required one).
    * any other option is an option of the temporary `table/2`, for example
      `options: "STRICT"`.
  """
  defmacro rebuild_table(table, opts \\ [], do: block) do
    quote do
      table = unquote(table)
      {copy, options} = Keyword.pop(unquote(opts), :copy, [])
      temporary = "#{table}_rebuild"

      execute(fn -> AshSqlite.Migration.__check_foreign_keys_off__(repo(), table) end)

      create table(temporary, [primary_key: false] ++ options) do
        unquote(block)
      end

      # the columns of both tables are only known once the new one exists
      execute(fn -> AshSqlite.Migration.__copy_rows__(repo(), table, temporary, copy) end)

      # While the old table is dropped, a view or trigger that mentions it points at nothing, and
      # the rename that follows refuses. The legacy behaviour leaves them alone. It is not on for
      # the rest of the migration, so that a `rename table` in it still updates what mentions it.
      execute(fn -> AshSqlite.Migration.__legacy_alter_table__(repo(), 1) end)
      drop(table(table))
      rename(table(temporary), to: table(table))
      execute(fn -> AshSqlite.Migration.__legacy_alter_table__(repo(), 0) end)
    end
  end

  @doc false
  def __copy_rows__(repo, table, temporary, copy) do
    old_columns = column_names(repo, table)
    new_columns = column_names(repo, temporary)

    unknown =
      copy |> Keyword.keys() |> Enum.map(&to_string/1) |> Enum.reject(&(&1 in new_columns))

    if unknown != [] do
      raise ArgumentError,
            "`copy:` for #{table} names #{Enum.join(unknown, ", ")}, which the new table " <>
              "does not have (it has #{Enum.join(new_columns, ", ")})"
    end

    expressions =
      for name <- new_columns,
          expression = copy_expression(copy, name, old_columns),
          do: {name, expression}

    if expressions == [] do
      raise ArgumentError,
            "`rebuild_table` for #{table} would copy nothing: the new table has no column in " <>
              "common with the old one and no `copy:`, so its rows would be lost"
    end

    names = Enum.map_join(expressions, ", ", fn {name, _} -> quote_name(name) end)
    selected = Enum.map_join(expressions, ", ", fn {_, expression} -> expression end)

    query!(
      repo,
      "INSERT INTO #{quote_name(temporary)} (#{names}) SELECT #{selected} FROM #{quote_name(table)}"
    )
  end

  defp copy_expression(copy, name, old_columns) do
    case Enum.find(copy, fn {new, _} -> to_string(new) == name end) do
      {_, from} when is_atom(from) -> quote_name(from)
      {_, sql} when is_binary(sql) -> sql
      nil -> if name in old_columns, do: quote_name(name)
    end
  end

  defp column_names(repo, table) do
    %{rows: rows} = quiet!(repo, "PRAGMA table_info(#{quote_name(table)})")
    Enum.map(rows, fn [_cid, name | _] -> name end)
  end

  defp quote_name(name), do: ~s("#{name}")

  # not `repo.query!/1`: ecto_libsql's repo has none
  # sobelow_skip ["SQL.Query"]
  defp query!(repo, statement), do: Ecto.Adapters.SQL.query!(repo, statement)

  # sobelow_skip ["SQL.Query"]
  defp quiet!(repo, statement), do: Ecto.Adapters.SQL.query!(repo, statement, [], log: false)

  defp pragma(repo, name) do
    %{rows: [[value]]} = quiet!(repo, "PRAGMA #{name}")
    value
  end

  @doc false
  def __check_foreign_keys__(repo) do
    case quiet!(repo, "PRAGMA foreign_key_check") do
      %{rows: []} ->
        :ok

      %{rows: rows} ->
        raise "foreign key check failed after rebuilding tables (table, rowid, parent, constraint): " <>
                inspect(rows)
    end
  end
end
