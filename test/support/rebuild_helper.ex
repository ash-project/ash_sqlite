# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.RebuildHelper do
  @moduledoc """
  Runs migrations against a real SQLite file, for the tests of `AshSqlite.Migration`.
  """
  alias AshSqlite.RebuildTestRepo

  # The repo the current test started (the process dictionary: the tests are not async)
  defp repo, do: Process.get(:rebuild_repo, RebuildTestRepo)

  @doc """
  Points `AshSqlite.RebuildTestRepo` at a new database file in `tmp_dir` and starts it.
  `repo_config` is merged into the repo's configuration (`pool_size: 2`, ...).
  Returns a context map the other helpers take.
  """
  def start(tmp_dir, repo_config \\ [], repo \\ RebuildTestRepo) do
    Process.put(:rebuild_repo, repo)

    ctx = %{
      db: Path.join(tmp_dir, "test.db"),
      snapshot_path: Path.join(tmp_dir, "snapshots"),
      migration_path: Path.join(tmp_dir, "migrations")
    }

    config =
      Keyword.merge(
        [
          database: ctx.db,
          pool_size: 1,
          migration_lock: false
        ],
        repo_config
      )

    Application.put_env(:ash_sqlite, repo, config)
    ExUnit.Callbacks.start_supervised!(repo)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:ash_sqlite, repo) end)

    ctx
  end

  @doc "Writes a migration, `body` being what goes in the module after `use AshSqlite.Migration`."
  def write_migration(ctx, version, name, body) do
    File.mkdir_p!(ctx.migration_path)
    module = Module.concat([repo(), Migrations, Macro.camelize(name)])

    File.write!(Path.join(ctx.migration_path, "#{version}_#{name}.exs"), """
    defmodule #{inspect(module)} do
      use AshSqlite.Migration

    #{body}
    end
    """)
  end

  @doc "Runs all pending migrations. Returns the versions run, or raises."
  def migrate(ctx) do
    Code.compiler_options(ignore_module_conflict: true)

    try do
      Ecto.Migrator.run(repo(), ctx.migration_path, :up, all: true, log: false)
    after
      Code.compiler_options(ignore_module_conflict: false)
    end
  end

  @doc "Rolls back the last `n` migrations."
  def rollback(ctx, n \\ 1) do
    Code.compiler_options(ignore_module_conflict: true)

    try do
      Ecto.Migrator.run(repo(), ctx.migration_path, :down, step: n, log: false)
    after
      Code.compiler_options(ignore_module_conflict: false)
    end
  end

  @doc "Runs SQL; returns the rows (lists)."
  def sql(statement, params \\ []) do
    Ecto.Adapters.SQL.query!(repo(), statement, params).rows
  end

  def columns(table) do
    "SELECT name, type, \"notnull\", dflt_value, pk FROM pragma_table_info('#{table}')"
    |> sql()
    |> Enum.map(fn [name, type, notnull, default, pk] ->
      %{name: name, type: type, notnull: notnull == 1, default: default, pk: pk}
    end)
  end

  @doc "Runs the pending migrations, which must fail. Returns the exception's message."
  def migrate_error(ctx) do
    migrate(ctx)
    flunk("expected the migration to fail")
  rescue
    error in ExUnit.AssertionError -> reraise error, __STACKTRACE__
    error -> Exception.message(error)
  end

  defp flunk(message), do: raise(ExUnit.AssertionError, message: message)

  @doc "The versions recorded in schema_migrations."
  def versions,
    do: "SELECT version FROM schema_migrations ORDER BY version" |> sql() |> List.flatten()

  @doc "Tables left over from a rebuild (named `*_rebuild`)."
  def leftovers do
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE '%\\_rebuild' ESCAPE '\\'"
    |> sql()
    |> List.flatten()
  end
end
