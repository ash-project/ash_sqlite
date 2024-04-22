defmodule AshSqlite.MixProject do
  use Mix.Project

  @description """
  A sqlite data layer for `Ash` resources. Leverages Ecto's sqlite
  support, and delegates to a configured repo.
  """

  @version "0.1.2-rc.0"

  def project do
    [
      app: :ash_sqlite,
      version: @version,
      elixir: "~> 1.11",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: @description,
      elixirc_paths: elixirc_paths(Mix.env()),
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.github": :test,
        "test.create": :test,
        "test.migrate": :test,
        "test.rollback": :test,
        "test.check_migrations": :test,
        "test.drop": :test,
        "test.generate_migrations": :test,
        "test.reset": :test
      ],
      dialyzer: [
        plt_add_apps: [:ecto, :ash, :mix]
      ],
      docs: docs(),
      aliases: aliases(),
      package: package(),
      source_url: "https://github.com/ash-project/ash_sqlite",
      homepage_url: "https://github.com/ash-project/ash_sqlite",
      consolidate_protocols: Mix.env() != :test
    ]
  end

  if Mix.env() == :test do
    def application() do
      [
        mod: {AshSqlite.TestApp, []}
      ]
    end
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      name: :ash_sqlite,
      licenses: ["MIT"],
      files: ~w(lib .formatter.exs mix.exs README* LICENSE*
      CHANGELOG* documentation),
      links: %{
        GitHub: "https://github.com/ash-project/ash_sqlite"
      }
    ]
  end

  defp extras() do
    "documentation/**/*.{md,livemd,cheatmd}"
    |> Path.wildcard()
    |> Enum.map(fn path ->
      title =
        path
        |> Path.basename(".md")
        |> Path.basename(".livemd")
        |> Path.basename(".cheatmd")
        |> String.split(~r/[-_]/)
        |> Enum.map_join(" ", &capitalize/1)
        |> case do
          "F A Q" ->
            "FAQ"

          other ->
            other
        end

      {String.to_atom(path),
       [
         title: title
       ]}
    end)
  end

  defp capitalize(string) do
    string
    |> String.split(" ")
    |> Enum.map(fn string ->
      [hd | tail] = String.graphemes(string)
      String.capitalize(hd) <> Enum.join(tail)
    end)
  end

  defp groups_for_extras() do
    [
      Tutorials: [
        ~r'documentation/tutorials'
      ],
      "How To": ~r'documentation/how_to',
      Topics: ~r'documentation/topics',
      DSLs: ~r'documentation/dsls'
    ]
  end

  defp docs do
    [
      main: "get-started-with-sqlite",
      source_ref: "v#{@version}",
      logo: "logos/small-logo.png",
      extras: extras(),
      spark: [
        mix_tasks: [
          SQLite: [
            Mix.Tasks.AshSqlite.GenerateMigrations,
            Mix.Tasks.AshSqlite.Create,
            Mix.Tasks.AshSqlite.Drop,
            Mix.Tasks.AshSqlite.Migrate,
            Mix.Tasks.AshSqlite.Rollback
          ]
        ],
        extensions: [
          %{
            module: AshSqlite.DataLayer,
            name: "AshSqlite",
            target: "Ash.Resource",
            type: "DataLayer"
          }
        ]
      ],
      groups_for_extras: groups_for_extras(),
      groups_for_modules: [
        AshSqlite: [
          AshSqlite,
          AshSqlite.Repo,
          AshSqlite.DataLayer
        ],
        Utilities: [
          AshSqlite.ManualRelationship
        ],
        Introspection: [
          AshSqlite.DataLayer.Info,
          AshSqlite.CustomExtension,
          AshSqlite.CustomIndex,
          AshSqlite.Reference,
          AshSqlite.Statement
        ],
        Types: [
          AshSqlite.Type
        ],
        Expressions: [
          AshSqlite.Functions.Fragment,
          AshSqlite.Functions.Like
        ],
        Internals: ~r/.*/
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ecto_sql, "~> 3.9"},
      {:ecto_sqlite3, "~> 0.12"},
      {:ash_sql, "~> 0.1.0-rc.2"},
      {:ecto, "~> 3.9"},
      {:jason, "~> 1.0"},
      {:ash, ash_version("~> 3.0.0-rc.0")},
      {:git_ops, "~> 2.5", only: [:dev, :test]},
      {:ex_doc, "~> 0.22", only: [:dev, :test], runtime: false},
      {:ex_check, "~> 0.14", only: [:dev, :test]},
      {:credo, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:dialyxir, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:sobelow, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:mix_audit, ">= 0.0.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp ash_version(default_version) do
    case System.get_env("ASH_VERSION") do
      nil ->
        default_version

      "local" ->
        [path: "../ash", override: true]

      "main" ->
        [git: "https://github.com/ash-project/ash.git"]

      version when is_binary(version) ->
        "~> #{version}"

      version ->
        version
    end
  end

  defp aliases do
    [
      sobelow:
        "sobelow --skip -i Config.Secrets --ignore-files lib/migration_generator/migration_generator.ex",
      credo: "credo --strict",
      docs: [
        "spark.cheat_sheets",
        "docs",
        "spark.replace_doc_links",
        "spark.cheat_sheets_in_search"
      ],
      "spark.formatter": "spark.formatter --extensions AshSqlite.DataLayer",
      "spark.cheat_sheets": "spark.cheat_sheets --extensions AshSqlite.DataLayer",
      "spark.cheat_sheets_in_search":
        "spark.cheat_sheets_in_search --extensions AshSqlite.DataLayer",
      "test.generate_migrations": "ash_sqlite.generate_migrations",
      "test.check_migrations": "ash_sqlite.generate_migrations --check",
      "test.migrate": "ash_sqlite.migrate",
      "test.rollback": "ash_sqlite.rollback",
      "test.create": "ash_sqlite.create",
      "test.reset": ["test.drop", "test.create", "test.migrate"],
      "test.drop": "ash_sqlite.drop"
    ]
  end
end
