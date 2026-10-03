# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Verifiers.VerifyRepo do
  @moduledoc false
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier

  def verify(dsl) do
    repo = Verifier.get_option(dsl, [:sqlite], :repo)

    cond do
      is_function(repo) ->
        :ok

      match?({:error, _}, Code.ensure_compiled(repo)) ->
        {:error, "Could not find repo module #{repo}"}

      repo.__adapter__() not in [Ecto.Adapters.SQLite3, Ecto.Adapters.LibSql] ->
        {:error, "Expected a repo using `Ecto.Adapters.SQLite3` or `Ecto.Adapters.LibSql`"}

      true ->
        :ok
    end
  end
end
