defmodule AshSqlite.Aggregate do
  @moduledoc false

  require Ecto.Query

  def add_subquery_aggregate_select(
        query,
        relationship_path,
        %{kind: :first} = aggregate,
        resource,
        is_single?
      ) do
    query = AshSqlite.DataLayer.default_bindings(query, aggregate.resource)

    ref = %Ash.Query.Ref{
      attribute: aggregate_field(aggregate, resource, relationship_path, query),
      relationship_path: relationship_path,
      resource: query.__ash_bindings__.resource
    }

    type = AshSqlite.Types.parameterized_type(aggregate.type, aggregate.constraints)

    binding =
      AshSqlite.DataLayer.get_binding(
        query.__ash_bindings__.resource,
        relationship_path,
        query,
        [:left, :inner, :root]
      )

    field = AshSqlite.Expr.dynamic_expr(query, ref, query.__ash_bindings__, false)

    sorted =
      if has_sort?(aggregate.query) do
        {:ok, sort_expr} =
          AshSqlite.Sort.sort(
            query,
            aggregate.query.sort,
            Ash.Resource.Info.related(
              query.__ash_bindings__.resource,
              relationship_path
            ),
            relationship_path,
            binding,
            true
          )

        question_marks = Enum.map(sort_expr, fn _ -> " ? " end)

        {:ok, expr} =
          AshSqlite.Functions.Fragment.casted_new(
            ["array_agg(? ORDER BY #{question_marks})", field] ++ sort_expr
          )

        AshSqlite.Expr.dynamic_expr(query, expr, query.__ash_bindings__, false)
      else
        Ecto.Query.dynamic(
          [row],
          fragment("array_agg(?)", ^field)
        )
      end

    filtered = filter_field(sorted, query, aggregate, relationship_path, is_single?)

    value = Ecto.Query.dynamic(fragment("(?)[1]", ^filtered))

    with_default =
      if aggregate.default_value do
        if type do
          Ecto.Query.dynamic(coalesce(^value, type(^aggregate.default_value, ^type)))
        else
          Ecto.Query.dynamic(coalesce(^value, ^aggregate.default_value))
        end
      else
        value
      end

    casted =
      if type do
        Ecto.Query.dynamic(type(^with_default, ^type))
      else
        with_default
      end

    select_or_merge(query, aggregate.name, casted)
  end

  def add_subquery_aggregate_select(
        query,
        relationship_path,
        %{kind: :list} = aggregate,
        resource,
        is_single?
      ) do
    query = AshSqlite.DataLayer.default_bindings(query, aggregate.resource)
    type = AshSqlite.Types.parameterized_type(aggregate.type, aggregate.constraints)

    binding =
      AshSqlite.DataLayer.get_binding(
        query.__ash_bindings__.resource,
        relationship_path,
        query,
        [:left, :inner, :root]
      )

    ref = %Ash.Query.Ref{
      attribute: aggregate_field(aggregate, resource, relationship_path, query),
      relationship_path: relationship_path,
      resource: query.__ash_bindings__.resource
    }

    field = AshSqlite.Expr.dynamic_expr(query, ref, query.__ash_bindings__, false)

    sorted =
      if has_sort?(aggregate.query) do
        {:ok, sort_expr} =
          AshSqlite.Sort.sort(
            query,
            aggregate.query.sort,
            Ash.Resource.Info.related(
              query.__ash_bindings__.resource,
              relationship_path
            ),
            relationship_path,
            binding,
            true
          )

        question_marks = Enum.map(sort_expr, fn _ -> " ? " end)

        distinct =
          if Map.get(aggregate, :uniq?) do
            "DISTINCT "
          else
            ""
          end

        {:ok, expr} =
          AshSqlite.Functions.Fragment.casted_new(
            ["array_agg(#{distinct}? ORDER BY #{question_marks})", field] ++ sort_expr
          )

        AshSqlite.Expr.dynamic_expr(query, expr, query.__ash_bindings__, false)
      else
        if Map.get(aggregate, :uniq?) do
          Ecto.Query.dynamic(
            [row],
            fragment("array_agg(DISTINCT ?)", ^field)
          )
        else
          Ecto.Query.dynamic(
            [row],
            fragment("array_agg(?)", ^field)
          )
        end
      end

    filtered = filter_field(sorted, query, aggregate, relationship_path, is_single?)

    with_default =
      if aggregate.default_value do
        if type do
          Ecto.Query.dynamic(coalesce(^filtered, type(^aggregate.default_value, ^type)))
        else
          Ecto.Query.dynamic(coalesce(^filtered, ^aggregate.default_value))
        end
      else
        filtered
      end

    cast =
      if type do
        Ecto.Query.dynamic(type(^with_default, ^type))
      else
        with_default
      end

    select_or_merge(query, aggregate.name, cast)
  end

  def add_subquery_aggregate_select(
        query,
        relationship_path,
        %{kind: kind} = aggregate,
        resource,
        is_single?
      )
      when kind in [:count, :sum, :avg, :max, :min, :custom] do
    query = AshSqlite.DataLayer.default_bindings(query, aggregate.resource)

    ref = %Ash.Query.Ref{
      attribute: aggregate_field(aggregate, resource, relationship_path, query),
      relationship_path: relationship_path,
      resource: resource
    }

    field =
      if kind == :custom do
        # we won't use this if its custom so don't try to make one
        nil
      else
        AshSqlite.Expr.dynamic_expr(query, ref, query.__ash_bindings__, false)
      end

    type = AshSqlite.Types.parameterized_type(aggregate.type, aggregate.constraints)

    binding =
      AshSqlite.DataLayer.get_binding(
        query.__ash_bindings__.resource,
        relationship_path,
        query,
        [:left, :inner, :root]
      )

    field =
      case kind do
        :count ->
          if Map.get(aggregate, :uniq?) do
            Ecto.Query.dynamic([row], count(^field, :distinct))
          else
            Ecto.Query.dynamic([row], count(^field))
          end

        :sum ->
          Ecto.Query.dynamic([row], sum(^field))

        :avg ->
          Ecto.Query.dynamic([row], avg(^field))

        :max ->
          Ecto.Query.dynamic([row], max(^field))

        :min ->
          Ecto.Query.dynamic([row], min(^field))

        :custom ->
          {module, opts} = aggregate.implementation

          module.dynamic(opts, binding)
      end

    filtered = filter_field(field, query, aggregate, relationship_path, is_single?)

    with_default =
      if aggregate.default_value do
        if type do
          Ecto.Query.dynamic(coalesce(^filtered, type(^aggregate.default_value, ^type)))
        else
          Ecto.Query.dynamic(coalesce(^filtered, ^aggregate.default_value))
        end
      else
        filtered
      end

    cast =
      if type do
        Ecto.Query.dynamic(type(^with_default, ^type))
      else
        with_default
      end

    select_or_merge(query, aggregate.name, cast)
  end

  defp filter_field(field, _query, _aggregate, _relationship_path, true) do
    field
  end

  defp filter_field(field, query, aggregate, relationship_path, _is_single?) do
    if has_filter?(aggregate.query) do
      filter =
        Ash.Filter.move_to_relationship_path(
          aggregate.query.filter,
          relationship_path
        )

      expr =
        AshSqlite.Expr.dynamic_expr(
          query,
          filter,
          query.__ash_bindings__,
          false,
          AshSqlite.Types.parameterized_type(aggregate.type, aggregate.constraints)
        )

      Ecto.Query.dynamic(filter(^field, ^expr))
    else
      field
    end
  end

  defp has_filter?(nil), do: false
  defp has_filter?(%{filter: nil}), do: false
  defp has_filter?(%{filter: %Ash.Filter{expression: nil}}), do: false
  defp has_filter?(%{filter: %Ash.Filter{}}), do: true
  defp has_filter?(_), do: false

  defp has_sort?(nil), do: false
  defp has_sort?(%{sort: nil}), do: false
  defp has_sort?(%{sort: []}), do: false
  defp has_sort?(%{sort: _}), do: true
  defp has_sort?(_), do: false

  defp select_or_merge(query, aggregate_name, casted) do
    query =
      if query.select do
        query
      else
        Ecto.Query.select(query, %{})
      end

    Ecto.Query.select_merge(query, ^%{aggregate_name => casted})
  end

  defp aggregate_field(aggregate, resource, _relationship_path, _query) do
    case Ash.Resource.Info.field(
           resource,
           aggregate.field || List.first(Ash.Resource.Info.primary_key(resource))
         ) do
      %Ash.Resource.Calculation{calculation: {module, opts}} = calculation ->
        {:ok, query_calc} =
          Ash.Query.Calculation.new(
            calculation.name,
            module,
            opts,
            calculation.type,
            Map.get(aggregate, :context, %{})
          )

        query_calc

      other ->
        other
    end
  end
end
