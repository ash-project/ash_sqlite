# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

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
  config :ash, :warn_on_transaction_hooks?, false

  config :ash_sqlite, AshSqlite.TestRepo,
    database: Path.join(__DIR__, "../test/test.db"),
    pool_size: 1,
    migration_lock: false,
    pool: Ecto.Adapters.SQL.Sandbox,
    migration_primary_key: [name: :id, type: :binary_id]

  config :ash_sqlite, AshSqlite.DevTestRepo,
    database: Path.join(__DIR__, "../test/dev_test.db"),
    pool_size: 1,
    migration_lock: false,
    pool: Ecto.Adapters.SQL.Sandbox,
    migration_primary_key: [name: :id, type: :binary_id]

  # A real database, and started under its own name in `test_helper.exs`. This is the
  # database a `global? true` resource on this module uses: one copy of its rows,
  # reached without a tenant binding.
  config :ash_sqlite, AshSqlite.TenantRepo,
    database: Path.join(__DIR__, "../test/tenant_shared.db"),
    pool: DBConnection.ConnectionPool,
    pool_size: 1,
    migration_lock: false,
    migration_primary_key: [name: :id, type: :binary_id]

  config :ash_sqlite,
    ecto_repos: [AshSqlite.TestRepo, AshSqlite.DevTestRepo],
    ash_domains: [
      AshSqlite.Test.Domain
    ]

  config :logger, level: :warning
end
