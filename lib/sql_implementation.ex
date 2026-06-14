# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.SqlImplementation do
  @moduledoc false
  use AshSql.Implementation

  require Ecto.Query
  require Ash.Expr

  @impl true
  def manual_relationship_function, do: :ash_sqlite_join

  @impl true
  def manual_relationship_subquery_function, do: :ash_sqlite_subquery

  @impl true
  def strpos_function, do: "instr"

  @impl true
  def ilike?, do: false

  @impl true
  def expr(
        query,
        %Ash.Query.Operator.In{
          right: %Ash.Query.Function.Type{arguments: [right | _]}
        } = op,
        bindings,
        embedded?,
        acc,
        type
      )
      when is_list(right) or is_struct(right, MapSet) do
    expr(query, %{op | right: right}, bindings, embedded?, acc, type)
  end

  def expr(
        query,
        %Ash.Query.Operator.In{left: left, right: right, embedded?: pred_embedded?},
        bindings,
        embedded?,
        acc,
        _type
      )
      when is_list(right) or is_struct(right, MapSet) do
    {item_type, constraints} = in_item_type(left)
    context_embedded? = pred_embedded? || embedded?
    values = Enum.to_list(right)

    if Enum.any?(values, &complex_in_value?/1) do
      expand_in_to_or(query, left, values, bindings, context_embedded?, acc, item_type)
    else
      {left_expr, acc} =
        AshSql.Expr.dynamic_expr(
          query,
          left,
          in_left_bindings(bindings, item_type, constraints),
          context_embedded?,
          in_left_type(item_type, constraints),
          acc
        )

      values = dump_in_values(query, bindings, values, item_type, constraints)

      {:ok, Ecto.Query.dynamic(^left_expr in ^values), acc}
    end
  end

  def expr(
        query,
        %like{arguments: [arg1, arg2], embedded?: pred_embedded?},
        bindings,
        embedded?,
        acc,
        type
      )
      when like in [AshSqlite.Functions.Like, AshSqlite.Functions.ILike] do
    {arg1, acc} =
      AshSql.Expr.dynamic_expr(query, arg1, bindings, pred_embedded? || embedded?, :string, acc)

    {arg2, acc} =
      AshSql.Expr.dynamic_expr(query, arg2, bindings, pred_embedded? || embedded?, :string, acc)

    inner_dyn =
      if like == AshSqlite.Functions.Like do
        Ecto.Query.dynamic(like(^arg1, ^arg2))
      else
        Ecto.Query.dynamic(like(fragment("LOWER(?)", ^arg1), fragment("LOWER(?)", ^arg2)))
      end

    # `like`/`ilike` produce SQLite's 0/1 integer result, so cast back to a
    # proper boolean when that's the expected output type. `type` typically
    # arrives as a `{Ash.Type.Boolean, constraints}` tuple, so match both forms.
    if boolean_type?(type) do
      {:ok, Ecto.Query.dynamic(type(^inner_dyn, :boolean)), acc}
    else
      {:ok, inner_dyn, acc}
    end
  end

  def expr(
        query,
        %Ash.Query.Function.GetPath{
          arguments: [%Ash.Query.Ref{attribute: %{type: type}}, right]
        } = get_path,
        bindings,
        embedded?,
        acc,
        nil
      )
      when is_atom(type) and is_list(right) do
    if Ash.Type.embedded_type?(type) do
      type = determine_type_at_path(type, right)

      do_get_path(query, get_path, bindings, embedded?, acc, type)
    else
      do_get_path(query, get_path, bindings, embedded?, acc)
    end
  end

  def expr(
        query,
        %Ash.Query.Function.GetPath{
          arguments: [%Ash.Query.Ref{attribute: %{type: {:array, type}}}, right]
        } = get_path,
        bindings,
        embedded?,
        acc,
        nil
      )
      when is_atom(type) and is_list(right) do
    if Ash.Type.embedded_type?(type) do
      type = determine_type_at_path(type, right)
      do_get_path(query, get_path, bindings, embedded?, acc, type)
    else
      do_get_path(query, get_path, bindings, embedded?, acc)
    end
  end

  def expr(
        query,
        %Ash.Query.Function.GetPath{} = get_path,
        bindings,
        embedded?,
        acc,
        type
      ) do
    do_get_path(query, get_path, bindings, embedded?, acc, type)
  end

  def expr(
        query,
        %Ash.Query.Function.StringTrim{arguments: [value], embedded?: pred_embedded?},
        bindings,
        embedded?,
        acc,
        type
      ) do
    {expr, acc} =
      AshSql.Expr.dynamic_expr(
        query,
        %Ash.Query.Function.Fragment{
          embedded?: pred_embedded?,
          arguments: [
            raw: "TRIM(",
            expr: value,
            raw: ")"
          ]
        },
        bindings,
        embedded?,
        type,
        acc
      )

    {:ok, expr, acc}
  end

  def expr(
        query,
        %Ash.Query.Function.StringLength{arguments: [value], embedded?: pred_embedded?},
        bindings,
        embedded?,
        acc,
        type
      ) do
    {expr, acc} =
      AshSql.Expr.dynamic_expr(
        query,
        %Ash.Query.Function.Fragment{
          embedded?: pred_embedded?,
          arguments: [
            raw: "LENGTH(",
            expr: value,
            raw: ")"
          ]
        },
        bindings,
        embedded?,
        type,
        acc
      )

    {:ok, expr, acc}
  end

  # Handle comparisons involving map values - SQLite can't directly compare maps,
  # so we convert both sides to JSON strings for comparison
  def expr(
        query,
        %Ash.Query.Operator.NotEq{left: left, right: right, embedded?: pred_embedded?},
        bindings,
        embedded?,
        acc,
        type
      )
      when is_non_struct_map(left) or is_non_struct_map(right) do
    handle_map_comparison(query, :!=, left, right, pred_embedded?, bindings, embedded?, acc, type)
  end

  def expr(
        query,
        %Ash.Query.Operator.Eq{left: left, right: right, embedded?: pred_embedded?},
        bindings,
        embedded?,
        acc,
        type
      )
      when is_non_struct_map(left) or is_non_struct_map(right) do
    handle_map_comparison(query, :==, left, right, pred_embedded?, bindings, embedded?, acc, type)
  end

  @impl true
  def expr(
        _query,
        _expr,
        _bindings,
        _embedded?,
        _acc,
        _type
      ) do
    :error
  end

  defp handle_map_comparison(
         query,
         operator,
         left,
         right,
         pred_embedded?,
         bindings,
         embedded?,
         acc,
         type
       ) do
    {left_expr, acc} = as_json(query, left, pred_embedded?, bindings, embedded?, acc, type)
    {right_expr, acc} = as_json(query, right, pred_embedded?, bindings, embedded?, acc, type)

    result =
      case operator do
        :== -> Ecto.Query.dynamic(^left_expr == ^right_expr)
        :!= -> Ecto.Query.dynamic(^left_expr != ^right_expr)
      end

    {:ok, result, acc}
  end

  defp as_json(query, value, pred_embedded?, bindings, embedded?, acc, type) do
    if plain_map?(value) do
      AshSql.Expr.dynamic_expr(
        query,
        Jason.encode!(value),
        bindings,
        pred_embedded? || embedded?,
        :string,
        acc
      )
    else
      AshSql.Expr.dynamic_expr(
        query,
        %Ash.Query.Function.Fragment{
          embedded?: pred_embedded?,
          arguments: [raw: "json(", expr: value, raw: ")"]
        },
        bindings,
        embedded?,
        type,
        acc
      )
    end
  end

  defp plain_map?(value) when is_map(value) and not is_struct(value), do: true
  defp plain_map?(_), do: false

  defp in_item_type(left) do
    case Ash.Expr.determine_type(left) do
      {:ok, {type, constraints}} -> {type, constraints || []}
      _ -> {nil, []}
    end
  end

  defp in_left_bindings(bindings, item_type, constraints) do
    if ci_string_type?(item_type, constraints) do
      bindings
    else
      Map.put(bindings, :no_cast?, true)
    end
  end

  defp in_left_type(item_type, constraints) do
    if ci_string_type?(item_type, constraints) do
      if constraints == [] do
        item_type
      else
        {item_type, constraints}
      end
    end
  end

  defp complex_in_value?(value) do
    Ash.Expr.expr?(value) || is_list(value) || (is_map(value) && !is_struct(value))
  end

  defp expand_in_to_or(query, left, values, bindings, embedded?, acc, type) do
    values
    |> Enum.reduce(nil, fn value, acc ->
      if is_nil(acc) do
        %Ash.Query.Operator.Eq{left: left, right: value}
      else
        %Ash.Query.BooleanExpression{
          op: :or,
          left: acc,
          right: %Ash.Query.Operator.Eq{left: left, right: value}
        }
      end
    end)
    |> then(fn expr ->
      {expr, acc} = AshSql.Expr.dynamic_expr(query, expr, bindings, embedded?, type, acc)
      {:ok, expr, acc}
    end)
  end

  defp dump_in_values(_query, _bindings, values, nil, _constraints) do
    Enum.map(values, fn
      # Preserve the old equality fallback for untyped atom values when the LHS has no attribute.
      value when is_atom(value) and not is_boolean(value) and not is_nil(value) ->
        to_string(value)

      value ->
        value
    end)
  end

  defp dump_in_values(query, bindings, values, item_type, constraints) do
    ecto_type =
      parameterized_type(item_type, constraints) ||
        item_type
        |> Ash.Type.get_type()
        |> Ash.Type.storage_type(constraints)

    adapter = sqlite_adapter(query, bindings)

    Enum.map(values, fn value ->
      case Ecto.Type.adapter_dump(adapter, ecto_type, value) do
        {:ok, value} -> value
        # Some custom/already-dumped values may not accept another dump; keep the old value.
        _ -> value
      end
    end)
  end

  # Every `AshSqlite.Repo` is compiled with `adapter: Ecto.Adapters.SQLite3`,
  # so we can extract the adapter without asserting on it.
  defp sqlite_adapter(query, bindings) do
    bindings
    |> Map.fetch!(:resource)
    |> AshSql.dynamic_repo(__MODULE__, query)
    |> then(& &1.__adapter__())
  end

  defp boolean_type?(Ash.Type.Boolean), do: true
  defp boolean_type?({Ash.Type.Boolean, _}), do: true
  defp boolean_type?(:boolean), do: true
  defp boolean_type?({:boolean, _}), do: true
  defp boolean_type?(_), do: false

  defp ci_string_type?({:parameterized, {inner_type, constraints}}, []) do
    parameterized_ci_string_type?(inner_type, constraints)
  end

  defp ci_string_type?({:parameterized, inner_type, constraints}, []) do
    parameterized_ci_string_type?(inner_type, constraints)
  end

  defp ci_string_type?(type, constraints) when is_atom(type) do
    type = Ash.Type.get_type(type)
    Ash.Type.ash_type?(type) && Ash.Type.storage_type(type, constraints) == :ci_string
  end

  defp ci_string_type?(_, _), do: false

  defp parameterized_ci_string_type?(inner_type, constraints)
       when is_atom(inner_type) and is_list(constraints) do
    function_exported?(inner_type, :type, 1) && inner_type.type(constraints) == :ci_string
  end

  defp parameterized_ci_string_type?(_, _), do: false

  @impl true
  def type_expr(expr, nil), do: expr

  def type_expr(expr, type) when is_atom(type) do
    type = Ash.Type.get_type(type)

    cond do
      !Ash.Type.ash_type?(type) ->
        Ecto.Query.dynamic(type(^expr, ^type))

      Ash.Type.storage_type(type, []) == :ci_string ->
        Ecto.Query.dynamic(fragment("(? COLLATE NOCASE)", ^expr))

      true ->
        Ecto.Query.dynamic(type(^expr, ^Ash.Type.storage_type(type, [])))
    end
  end

  def type_expr(expr, type) do
    case type do
      {:parameterized, {inner_type, constraints}} ->
        if inner_type.type(constraints) == :ci_string do
          Ecto.Query.dynamic(fragment("(? COLLATE NOCASE)", ^expr))
        else
          Ecto.Query.dynamic(type(^expr, ^type))
        end

      nil ->
        expr

      type ->
        Ecto.Query.dynamic(type(^expr, ^type))
    end
  end

  @impl true
  def table(resource) do
    AshSqlite.DataLayer.Info.table(resource)
  end

  @impl true
  def schema(_resource) do
    nil
  end

  @impl true
  def repo(resource, kind) do
    AshSqlite.DataLayer.Info.repo(resource, kind)
  end

  @impl true
  def multicolumn_distinct?, do: false

  @impl true
  def parameterized_type({:parameterized, _} = type, _) do
    type
  end

  def parameterized_type({:parameterized, _, _} = type, _) do
    type
  end

  def parameterized_type({:in, type}, constraints) do
    parameterized_type({:array, type}, constraints)
  end

  def parameterized_type({:array, type}, constraints) do
    case parameterized_type(type, constraints[:items] || []) do
      nil ->
        nil

      type ->
        {:array, type}
    end
  end

  def parameterized_type({type, constraints}, []) do
    parameterized_type(type, constraints)
  end

  def parameterized_type(type, _constraints)
      when type in [Ash.Type.Map, Ash.Type.Map.EctoType],
      do: nil

  def parameterized_type(type, constraints) do
    if Ash.Type.ash_type?(type) do
      cast_in_query? =
        if function_exported?(Ash.Type, :cast_in_query?, 2) do
          Ash.Type.cast_in_query?(type, constraints)
        else
          Ash.Type.cast_in_query?(type)
        end

      if cast_in_query? do
        parameterized_type(Ash.Type.ecto_type(type), constraints)
      else
        nil
      end
    else
      if is_atom(type) && :erlang.function_exported(type, :type, 1) do
        Ecto.ParameterizedType.init(type, constraints)
      else
        type
      end
    end
  end

  @impl true
  def determine_types(mod, args, returns \\ nil) do
    returns =
      case returns do
        {:parameterized, _} -> nil
        {:array, {:parameterized, _}} -> nil
        {:array, {type, constraints}} when type != :array -> {type, [items: constraints]}
        {:array, _} -> nil
        {type, constraints} -> {type, constraints}
        other -> other
      end

    {types, new_returns} = Ash.Expr.determine_types(mod, args, returns)

    {types, new_returns || returns}
  end

  defp do_get_path(
         query,
         %Ash.Query.Function.GetPath{arguments: [left, right], embedded?: pred_embedded?},
         bindings,
         embedded?,
         acc,
         type \\ nil
       ) do
    path = "$." <> Enum.join(right, ".")

    {expr, acc} =
      AshSql.Expr.dynamic_expr(
        query,
        %Ash.Query.Function.Fragment{
          embedded?: pred_embedded?,
          arguments: [
            raw: "json_extract(",
            expr: left,
            raw: ", ",
            expr: path,
            raw: ")"
          ]
        },
        bindings,
        embedded?,
        type,
        acc
      )

    if type do
      {expr, acc} =
        AshSql.Expr.dynamic_expr(
          query,
          %Ash.Query.Function.Type{arguments: [expr, type, []]},
          bindings,
          embedded?,
          type,
          acc
        )

      {:ok, expr, acc}
    else
      {:ok, expr, acc}
    end
  end

  defp determine_type_at_path(type, path) do
    path
    |> Enum.reject(&is_integer/1)
    |> do_determine_type_at_path(type)
  end

  defp do_determine_type_at_path([], _), do: nil

  defp do_determine_type_at_path([item], type) do
    case Ash.Resource.Info.attribute(type, item) do
      nil ->
        nil

      %{type: {:array, type}, constraints: constraints} ->
        constraints = constraints[:items] || []

        {type, constraints}

      %{type: type, constraints: constraints} ->
        {type, constraints}
    end
  end

  defp do_determine_type_at_path([item | rest], type) do
    case Ash.Resource.Info.attribute(type, item) do
      nil ->
        nil

      %{type: {:array, type}} ->
        if Ash.Type.embedded_type?(type) do
          type
        else
          nil
        end

      %{type: type} ->
        if Ash.Type.embedded_type?(type) do
          type
        else
          nil
        end
    end
    |> case do
      nil ->
        nil

      type ->
        do_determine_type_at_path(rest, type)
    end
  end
end
