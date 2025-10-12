# SPDX-FileCopyrightText: 2020 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Mix.Helpers do
  @moduledoc false
  def domains!(opts, args) do
    apps =
      if apps_paths = Mix.Project.apps_paths() do
        apps_paths |> Map.keys() |> Enum.sort()
      else
        [Mix.Project.config()[:app]]
      end

    configured_domains = Enum.flat_map(apps, &Application.get_env(&1, :ash_domains, []))

    domains =
      if opts[:domains] && opts[:domains] != "" do
        opts[:domains]
        |> Kernel.||("")
        |> String.split(",")
        |> Enum.flat_map(fn
          "" ->
            []

          domain ->
            [Module.concat([domain])]
        end)
      else
        configured_domains
      end

    domains
    |> Enum.map(&ensure_compiled(&1, args))
    |> case do
      [] ->
        []

      domains ->
        domains
    end
  end

  def repos!(opts, args) do
    if opts[:domains] && opts[:domains] != "" do
      domains = domains!(opts, args)

      resources =
        domains
        |> Enum.flat_map(&Ash.Domain.Info.resources/1)
        |> Enum.filter(&(Ash.DataLayer.data_layer(&1) == AshSqlite.DataLayer))
        |> case do
          [] ->
            raise """
            No resources with `data_layer: AshSqlite.DataLayer` found in the domains #{Enum.map_join(domains, ",", &inspect/1)}.

            Must be able to find at least one resource with `data_layer: AshSqlite.DataLayer`.
            """

          resources ->
            resources
        end

      resources
      |> Enum.map(&AshSqlite.DataLayer.Info.repo/1)
      |> Enum.uniq()
      |> case do
        [] ->
          raise """
          No repos could be found configured on the resources in the domains: #{Enum.map_join(domains, ",", &inspect/1)}

          At least one resource must have a repo configured.

          The following resources were found with `data_layer: AshSqlite.DataLayer`:

          #{Enum.map_join(resources, "\n", &"* #{inspect(&1)}")}
          """

        repos ->
          repos
      end
    else
      if Code.ensure_loaded?(Mix.Tasks.App.Config) do
        Mix.Task.run("app.config", args)
      else
        Mix.Task.run("loadpaths", args)
        "--no-compile" not in args && Mix.Task.run("compile", args)
      end

      Mix.Project.config()[:app]
      |> Application.get_env(:ecto_repos, [])
      |> Enum.filter(fn repo ->
        Spark.implements_behaviour?(repo, AshSqlite.Repo)
      end)
    end
  end

  def delete_flag(args, arg) do
    case Enum.split_while(args, &(&1 != arg)) do
      {left, [_ | rest]} ->
        delete_flag(left ++ rest, arg)

      _ ->
        args
    end
  end

  def delete_arg(args, arg) do
    case Enum.split_while(args, &(&1 != arg)) do
      {left, [_, _ | rest]} ->
        delete_arg(left ++ rest, arg)

      _ ->
        args
    end
  end

  defp ensure_compiled(domain, args) do
    if Code.ensure_loaded?(Mix.Tasks.App.Config) do
      Mix.Task.run("app.config", args)
    else
      Mix.Task.run("loadpaths", args)
      "--no-compile" not in args && Mix.Task.run("compile", args)
    end

    case Code.ensure_compiled(domain) do
      {:module, _} ->
        domain
        |> Ash.Domain.Info.resources()
        |> Enum.each(&Code.ensure_compiled/1)

        # TODO: We shouldn't need to make sure that the resources are compiled

        domain

      {:error, error} ->
        Mix.raise("Could not load #{inspect(domain)}, error: #{inspect(error)}. ")
    end
  end

  def migrations_path(opts, repo) do
    opts[:migrations_path] || repo.config()[:migrations_path] || derive_migrations_path(repo)
  end

  def derive_migrations_path(repo) do
    config = repo.config()
    priv = config[:priv] || "priv/#{repo |> Module.split() |> List.last() |> Macro.underscore()}"
    app = Keyword.fetch!(config, :otp_app)
    Application.app_dir(app, Path.join(priv, "migrations"))
  end
end
