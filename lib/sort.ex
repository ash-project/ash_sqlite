defmodule AshSqlite.Sort do
  @moduledoc false
  require Ecto.Query

  def sort(
        query,
        sort,
        resource,
        relationship_path \\ [],
        binding \\ 0,
        return_order_by? \\ false
      ) do
    query = AshSqlite.DataLayer.default_bindings(query, resource)

    calcs =
      Enum.flat_map(sort, fn
        {%Ash.Query.Calculation{} = calculation, _} ->
          [calculation]

        _ ->
          []
      end)

    {:ok, query} =
      AshSqlite.Join.join_all_relationships(
        query,
        %Ash.Filter{
          resource: resource,
          expression: calcs
        },
        left_only?: true
      )

    sort
    |> sanitize_sort()
    |> Enum.reduce_while({:ok, []}, fn
      {order, %Ash.Query.Calculation{} = calc}, {:ok, query_expr} ->
        type =
          if calc.type do
            AshSqlite.Types.parameterized_type(calc.type, calc.constraints)
          else
            nil
          end

        calc.opts
        |> calc.module.expression(calc.context)
        |> Ash.Filter.hydrate_refs(%{
          resource: resource,
          aggregates: query.__ash_bindings__.aggregate_defs,
          calculations: %{},
          public?: false
        })
        |> Ash.Filter.move_to_relationship_path(relationship_path)
        |> case do
          {:ok, expr} ->
            expr =
              AshSqlite.Expr.dynamic_expr(query, expr, query.__ash_bindings__, false, type)

            {:cont, {:ok, query_expr ++ [{order, expr}]}}

          {:error, error} ->
            {:halt, {:error, error}}
        end

      {order, sort}, {:ok, query_expr} ->
        expr =
          Ecto.Query.dynamic(field(as(^binding), ^sort))

        {:cont, {:ok, query_expr ++ [{order, expr}]}}
    end)
    |> case do
      {:ok, []} ->
        if return_order_by? do
          {:ok, order_to_fragments([])}
        else
          {:ok, query}
        end

      {:ok, sort_exprs} ->
        if return_order_by? do
          {:ok, order_to_fragments(sort_exprs)}
        else
          new_query = Ecto.Query.order_by(query, ^sort_exprs)

          sort_expr = List.last(new_query.order_bys)

          new_query =
            new_query
            |> Map.update!(:windows, fn windows ->
              order_by_expr = %{sort_expr | expr: [order_by: sort_expr.expr]}
              Keyword.put(windows, :order, order_by_expr)
            end)
            |> Map.update!(:__ash_bindings__, &Map.put(&1, :__order__?, true))

          {:ok, new_query}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  def order_to_fragments([]), do: []

  def order_to_fragments(order) when is_list(order) do
    Enum.map(order, &do_order_to_fragments(&1))
  end

  def do_order_to_fragments({order, sort}) do
    case order do
      :asc ->
        Ecto.Query.dynamic([row], fragment("? ASC", ^sort))

      :desc ->
        Ecto.Query.dynamic([row], fragment("? DESC", ^sort))

      :asc_nulls_last ->
        Ecto.Query.dynamic([row], fragment("? ASC NULLS LAST", ^sort))

      :asc_nulls_first ->
        Ecto.Query.dynamic([row], fragment("? ASC NULLS FIRST", ^sort))

      :desc_nulls_first ->
        Ecto.Query.dynamic([row], fragment("? DESC NULLS FIRST", ^sort))

      :desc_nulls_last ->
        Ecto.Query.dynamic([row], fragment("? DESC NULLS LAST", ^sort))
        "DESC NULLS LAST"
    end
  end

  def order_to_postgres_order(dir) do
    case dir do
      :asc -> nil
      :asc_nils_last -> " ASC NULLS LAST"
      :asc_nils_first -> " ASC NULLS FIRST"
      :desc -> " DESC"
      :desc_nils_last -> " DESC NULLS LAST"
      :desc_nils_first -> " DESC NULLS FIRST"
    end
  end

  defp sanitize_sort(sort) do
    sort
    |> List.wrap()
    |> Enum.map(fn
      {sort, {order, context}} ->
        {ash_to_ecto_order(order), {sort, context}}

      {sort, order} ->
        {ash_to_ecto_order(order), sort}

      sort ->
        sort
    end)
  end

  defp ash_to_ecto_order(:asc_nils_last), do: :asc_nulls_last
  defp ash_to_ecto_order(:asc_nils_first), do: :asc_nulls_first
  defp ash_to_ecto_order(:desc_nils_last), do: :desc_nulls_last
  defp ash_to_ecto_order(:desc_nils_first), do: :desc_nulls_first
  defp ash_to_ecto_order(other), do: other
end
