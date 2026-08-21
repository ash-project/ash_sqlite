# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Transformers.CarryTenant do
  @moduledoc """
  Adds `AshSqlite.Changes.CarryTenant` to resources that need it.

  Only resources with both a `tenant_binder` and `strategy :context` need the
  tenant to reach `c:Ash.DataLayer.transaction/4`, and only they get the change —
  so a resource without a binder compiles to exactly what it did before.

  The alternative was to document that users add the change themselves. That is a
  footgun rather than a feature: leaving it out produces no error until the first
  action that opens a transaction, and the data layer already knows it needs the
  tenant, so it should arrange for it.
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
    !!Transformer.get_option(dsl, [:sqlite], :tenant_binder) and
      Ash.Resource.Info.multitenancy_strategy(dsl) == :context
  end

  defp carries_tenant?(dsl) do
    dsl
    |> Ash.Resource.Info.changes()
    |> Enum.any?(&match?(%{change: {AshSqlite.Changes.CarryTenant, _}}, &1))
  end
end
