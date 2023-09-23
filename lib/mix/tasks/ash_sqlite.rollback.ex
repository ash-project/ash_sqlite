defmodule Mix.Tasks.AshSqlite.Rollback do
  use Mix.Task

  import AshSqlite.MixHelpers,
    only: [migrations_path: 2]

  @shortdoc "Rolls back the repository migrations for all repositories in the provided (or configured) apis"

  @moduledoc """
  Reverts applied migrations in the given repository.
  Migrations are expected at "priv/YOUR_REPO/migrations" directory
  of the current application but it can be configured by specifying
  the `:priv` key under the repository configuration.
  Runs the latest applied migration by default. To roll back to
  a version number, supply `--to version_number`. To roll back a
  specific number of times, use `--step n`. To undo all applied
  migrations, provide `--all`.

  This is only really useful if your api or apis only use a single repo.
  If you have multiple repos and you want to run a single migration and/or
  migrate/roll them back to different points, you will need to use the
  ecto specific task, `mix ecto.migrate` and provide your repo name.

  ## Examples
      mix ash_sqlite.rollback
      mix ash_sqlite.rollback -r Custom.Repo
      mix ash_sqlite.rollback -n 3
      mix ash_sqlite.rollback --step 3
      mix ash_sqlite.rollback -v 20080906120000
      mix ash_sqlite.rollback --to 20080906120000

  ## Command line options
    * `--apis` - the apis who's repos should be rolledback
    * `--all` - revert all applied migrations
    * `--step` / `-n` - revert n number of applied migrations
    * `--to` / `-v` - revert all migrations down to and including version
    * `--quiet` - do not log migration commands
    * `--pool-size` - the pool size if the repository is started only for the task (defaults to 1)
    * `--log-sql` - log the raw sql migrations are running
  """

  @doc false
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          all: :boolean,
          step: :integer,
          to: :integer,
          start: :boolean,
          quiet: :boolean,
          pool_size: :integer,
          log_sql: :boolean
        ],
        aliases: [n: :step, v: :to]
      )

    repos = AshSqlite.MixHelpers.repos!(opts, args)

    repo_args =
      Enum.flat_map(repos, fn repo ->
        ["-r", to_string(repo)]
      end)

    rest_opts =
      args
      |> AshSqlite.MixHelpers.delete_arg("--apis")
      |> AshSqlite.MixHelpers.delete_arg("--migrations-path")

    for repo <- repos do
      Mix.Task.run(
        "ecto.rollback",
        repo_args ++ rest_opts ++ ["--migrations-path", migrations_path(opts, repo)]
      )

      Mix.Task.reenable("ecto.rollback")
    end
  end
end
