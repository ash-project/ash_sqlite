import Config

config :ash, :use_all_identities_in_manage_relationship?, false

if Mix.env() == :dev do
  config :git_ops,
    mix_project: AshSqlite.MixProject,
    changelog_file: "CHANGELOG.md",
    repository_url: "https://github.com/ash-project/ash_sqlite",
    # Instructs the tool to manage your mix version in your `mix.exs` file
    # See below for more information
    manage_mix_version?: true,
    # Instructs the tool to manage the version in your README.md
    # Pass in `true` to use `"README.md"` or a string to customize
    manage_readme_version: ["README.md", "documentation/tutorials/get-started-with-sqlite.md"],
    version_tag_prefix: "v"
end

if Mix.env() == :test do
  config :ash, :validate_api_resource_inclusion?, false
  config :ash, :validate_api_config_inclusion?, false

  config :ash_sqlite, AshSqlite.TestRepo,
    username: "sqlite",
    database: "ash_sqlite",
    hostname: "localhost",
    pool: Ecto.Adapters.SQL.Sandbox

  # sobelow_skip ["Config.Secrets"]
  config :ash_sqlite, AshSqlite.TestRepo, password: "sqlite"

  config :ash_sqlite, AshSqlite.TestRepo, migration_primary_key: [name: :id, type: :binary_id]

  config :ash_sqlite, AshSqlite.TestNoSandboxRepo,
    username: "sqlite",
    database: "ash_sqlite_test",
    hostname: "localhost"

  # sobelow_skip ["Config.Secrets"]
  config :ash_sqlite, AshSqlite.TestNoSandboxRepo, password: "sqlite"

  config :ash_sqlite, AshSqlite.TestNoSandboxRepo,
    migration_primary_key: [name: :id, type: :binary_id]

  config :ash_sqlite,
    ecto_repos: [AshSqlite.TestRepo, AshSqlite.TestNoSandboxRepo],
    ash_apis: [
      AshSqlite.Test.Api
    ]

  config :logger, level: :warning
end
