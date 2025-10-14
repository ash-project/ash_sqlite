# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs.contributors>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshSqlite.Create do
  use Mix.Task

  @shortdoc "Creates the repository storage"

  @switches [
    quiet: :boolean,
    domains: :string,
    no_compile: :boolean,
    no_deps_check: :boolean
  ]

  @aliases [
    q: :quiet
  ]

  @moduledoc """
  Create the storage for repos in all resources for the given (or configured) domains.

  ## Examples

      mix ash_sqlite.create
      mix ash_sqlite.create --domains MyApp.Domain1,MyApp.Domain2

  ## Command line options

    * `--domains` - the domains who's repos you want to migrate.
    * `--quiet` - do not log output
    * `--no-compile` - do not compile before creating
    * `--no-deps-check` - do not compile before creating
  """

  @doc false
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)

    repos = AshSqlite.Mix.Helpers.repos!(opts, args)

    repo_args =
      Enum.flat_map(repos, fn repo ->
        ["-r", to_string(repo)]
      end)

    rest_opts = AshSqlite.Mix.Helpers.delete_arg(args, "--domains")

    Mix.Task.reenable("ecto.create")

    Mix.Task.run("ecto.create", repo_args ++ rest_opts)
  end
end
