defmodule Mix.Tasks.AshSqlite.GenerateMigrations do
  @moduledoc """
  Generates migrations, and stores a snapshot of your resources.

  Options:

  * `domains` - a comma separated list of domain modules, for which migrations will be generated
  * `snapshot-path` - a custom path to store the snapshots, defaults to "priv/resource_snapshots"
  * `migration-path` - a custom path to store the migrations, defaults to "priv".
    Migrations are stored in a folder for each repo, so `priv/repo_name/migrations`
  * `drop-columns` - whether or not to drop columns as attributes are removed. See below for more
  * `name` -
      names the generated migrations, prepending with the timestamp. The default is `migrate_resources_<n>`,
      where `<n>` is the count of migrations matching `*migrate_resources*` plus one.
      For example, `--name add_special_column` would get a name like `20210708181402_add_special_column.exs`

  Flags:

  * `quiet` - messages for file creations will not be printed
  * `no-format` - files that are created will not be formatted with the code formatter
  * `dry-run` - no files are created, instead the new migration is printed
  * `check` - no files are created, returns an exit(1) code if the current snapshots and resources don't fit
  * `dev` - dev files are created (see Development Workflow section below)

  #### Snapshots

  Snapshots are stored in a folder for each table that migrations are generated for. Each snapshot is
  stored in a file with a timestamp of when it was generated.
  This is important because it allows for simultaneous work to be done on separate branches, and for rolling back
  changes more easily, e.g removing a generated migration, and deleting the most recent snapshot, without having to redo
  all of it

  #### Dropping columns

  Generally speaking, it is bad practice to drop columns when you deploy a change that
  would remove an attribute. The main reasons for this are backwards compatibility and rolling restarts.
  If you deploy an attribute removal, and run migrations. Regardless of your deployment sstrategy, you
  won't be able to roll back, because the data has been deleted. In a rolling restart situation, some of
  the machines/pods/whatever may still be running after the column has been deleted, causing errors. With
  this in mind, its best not to delete those columns until later, after the data has been confirmed unnecessary.
  To that end, the migration generator leaves the column dropping code commented. You can pass `--drop_columns`
  to tell it to uncomment those statements. Additionally, you can just uncomment that code on a case by case
  basis.

  #### Conflicts/Multiple Resources

  It will raise on conflicts that it can't resolve, like the same field with different
  types. It will prompt to resolve conflicts that can be resolved with human input.
  For example, if you remove an attribute and add an attribute, it will ask you if you are renaming
  the column in question. If not, it will remove one column and add the other.

  Additionally, it lowers things to the database where possible:

  #### Defaults
  There are three anonymous functions that will translate to database-specific defaults currently:

  * `&DateTime.utc_now/0`

  Non-function default values will be dumped to their native type and inspected. This may not work for some types,
  and may require manual intervention/patches to the migration generator code.

  #### Development Workflow

  The `--dev` flag enables a development-focused migration workflow that allows you to iterate
  on resource changes without committing to migration names prematurely:

  1. Make resource changes
  2. Run `mix ash_sqlite.generate_migrations --dev` to generate dev migrations
     - Creates migration files with `_dev.exs` suffix
     - Creates snapshot files with `_dev.json` suffix
     - No migration name required
  3. Continue making changes and running `--dev` as needed
  4. When ready, run `mix ash_sqlite.generate_migrations my_feature_name` to:
     - Remove all dev migrations and snapshots
     - Generate final named migrations that consolidate all changes
     - Create clean snapshots

  This workflow prevents migration history pollution during development while maintaining
  the ability to generate clean, well-named migrations for production.

  #### Identities

  Identities will cause the migration generator to generate unique constraints. If multiple
  resources target the same table, you will be asked to select the primary key, and any others
  will be added as unique constraints.
  """
  use Mix.Task

  @shortdoc "Generates migrations, and stores a snapshot of your resources"
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [
          domains: :string,
          snapshot_path: :string,
          migration_path: :string,
          quiet: :boolean,
          name: :string,
          no_format: :boolean,
          dry_run: :boolean,
          check: :boolean,
          dev: :boolean,
          auto_name: :boolean,
          drop_columns: :boolean
        ]
      )

    domains = AshSqlite.Mix.Helpers.domains!(opts, args)

    if Enum.empty?(domains) && !opts[:snapshots_only] do
      IO.warn("""
      No domains found, so no resource-related migrations will be generated.
      Pass the `--domains` option or configure `config :your_app, ash_domains: [...]`
      """)
    end

    opts =
      opts
      |> Keyword.put(:format, !opts[:no_format])
      |> Keyword.delete(:no_format)

    AshSqlite.MigrationGenerator.generate(domains, opts)
  end
end
