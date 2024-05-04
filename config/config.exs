import Config

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
    manage_readme_version: [
      "README.md",
      "documentation/tutorials/getting-started-with-ash-sqlite.md"
    ],
    version_tag_prefix: "v"
end

if Mix.env() == :test do
  config :ash, :validate_domain_resource_inclusion?, false
  config :ash, :validate_domain_config_inclusion?, false

  config :ash_sqlite, AshSqlite.TestRepo,
    database: Path.join(__DIR__, "../test/test.db"),
    pool_size: 1,
    migration_lock: false,
    pool: Ecto.Adapters.SQL.Sandbox,
    migration_primary_key: [name: :id, type: :binary_id]

  config :ash_sqlite,
    ecto_repos: [AshSqlite.TestRepo],
    ash_domains: [
      AshSqlite.Test.Domain
    ]

  config :logger, level: :warning
end
