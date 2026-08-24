# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Transformers.CarryTenant do
  @moduledoc """
  Adds `AshSqlite.Changes.CarryTenant` to resources that need it.
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def after?(_), do: true

  @impl true
  def transform(dsl) do
    if needs_tenant?(dsl) and not carries_tenant?(dsl) do
      {:ok,
       Transformer.add_entity(dsl, [:changes], %Ash.Resource.Change{
         change: {AshSqlite.Changes.CarryTenant, []},
         on: [:create, :update, :destroy],
         only_when_valid?: false,
         where: []
       })}
    else
      {:ok, dsl}
    end
  end

  defp needs_tenant?(dsl) do
    Ash.Resource.Info.multitenancy_strategy(dsl) == :context
  end

  defp carries_tenant?(dsl) do
    dsl
    |> Ash.Resource.Info.changes()
    |> Enum.any?(&match?(%{change: {AshSqlite.Changes.CarryTenant, _}}, &1))
  end
end
