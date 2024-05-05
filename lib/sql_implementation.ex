defmodule AshSqlite.SqlImplementation do
  @moduledoc false
  use AshSql.Implementation

  require Ecto.Query

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

    if type != Ash.Type.Boolean do
      {:ok, inner_dyn, acc}
    else
      {:ok, Ecto.Query.dynamic(type(^inner_dyn, ^type)), acc}
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
      {:parameterized, inner_type, constraints} ->
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
  def repo(resource, _kind) do
    AshSqlite.DataLayer.Info.repo(resource)
  end

  @impl true
  def multicolumn_distinct?, do: false

  @impl true
  def parameterized_type(type, constraints, no_maps? \\ false)

  def parameterized_type({:parameterized, _, _} = type, _, _) do
    type
  end

  def parameterized_type({:in, type}, constraints, no_maps?) do
    parameterized_type({:array, type}, constraints, no_maps?)
  end

  def parameterized_type({:array, type}, constraints, no_maps?) do
    case parameterized_type(type, constraints[:items] || [], no_maps?) do
      nil ->
        nil

      type ->
        {:array, type}
    end
  end

  def parameterized_type(type, _constraints, _no_maps?)
      when type in [Ash.Type.Map, Ash.Type.Map.EctoType],
      do: nil

  def parameterized_type(type, constraints, no_maps?) do
    if Ash.Type.ash_type?(type) do
      cast_in_query? =
        if function_exported?(Ash.Type, :cast_in_query?, 2) do
          Ash.Type.cast_in_query?(type, constraints)
        else
          Ash.Type.cast_in_query?(type)
        end

      if cast_in_query? do
        parameterized_type(Ash.Type.ecto_type(type), constraints, no_maps?)
      else
        nil
      end
    else
      if is_atom(type) && :erlang.function_exported(type, :type, 1) do
        {:parameterized, type, constraints || []}
      else
        type
      end
    end
  end

  @impl true
  def determine_types(mod, values) do
    Code.ensure_compiled(mod)

    cond do
      :erlang.function_exported(mod, :types, 0) ->
        mod.types()

      :erlang.function_exported(mod, :args, 0) ->
        mod.args()

      true ->
        [:any]
    end
    |> Enum.map(fn types ->
      case types do
        :same ->
          types =
            for _ <- values do
              :same
            end

          closest_fitting_type(types, values)

        :any ->
          for _ <- values do
            :any
          end

        types ->
          closest_fitting_type(types, values)
      end
    end)
    |> Enum.filter(fn types ->
      Enum.all?(types, &(vagueness(&1) == 0))
    end)
    |> case do
      [type] ->
        if type == :any || type == {:in, :any} do
          nil
        else
          type
        end

      # There are things we could likely do here
      # We only say "we know what types these are" when we explicitly know
      _ ->
        Enum.map(values, fn _ -> nil end)
    end
  end

  defp closest_fitting_type(types, values) do
    types_with_values = Enum.zip(types, values)

    types_with_values
    |> fill_in_known_types()
    |> clarify_types()
  end

  defp clarify_types(types) do
    basis =
      types
      |> Enum.map(&elem(&1, 0))
      |> Enum.min_by(&vagueness(&1))

    Enum.map(types, fn {type, _value} ->
      replace_same(type, basis)
    end)
  end

  defp replace_same({:in, type}, basis) do
    {:in, replace_same(type, basis)}
  end

  defp replace_same(:same, :same) do
    :any
  end

  defp replace_same(:same, {:in, :same}) do
    {:in, :any}
  end

  defp replace_same(:same, basis) do
    basis
  end

  defp replace_same(other, _basis) do
    other
  end

  defp fill_in_known_types(types) do
    Enum.map(types, &fill_in_known_type/1)
  end

  defp fill_in_known_type(
         {vague_type, %Ash.Query.Ref{attribute: %{type: type, constraints: constraints}}} = ref
       )
       when vague_type in [:any, :same] do
    if Ash.Type.ash_type?(type) do
      type = type |> parameterized_type(constraints, true) |> array_to_in()

      {type || :any, ref}
    else
      type =
        if is_atom(type) && :erlang.function_exported(type, :type, 1) do
          {:parameterized, type, []} |> array_to_in()
        else
          type |> array_to_in()
        end

      {type, ref}
    end
  end

  defp fill_in_known_type(
         {{:array, type}, %Ash.Query.Ref{attribute: %{type: {:array, type}} = attribute} = ref}
       ) do
    {:in, fill_in_known_type({type, %{ref | attribute: %{attribute | type: type}}})}
  end

  defp fill_in_known_type({type, value}), do: {array_to_in(type), value}

  defp array_to_in({:array, v}), do: {:in, array_to_in(v)}

  defp array_to_in({:parameterized, type, constraints}),
    do: {:parameterized, array_to_in(type), constraints}

  defp array_to_in(v), do: v

  defp vagueness({:in, type}), do: vagueness(type)
  defp vagueness(:same), do: 2
  defp vagueness(:any), do: 1
  defp vagueness(_), do: 0

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
    |> case do
      nil ->
        nil

      {type, constraints} ->
        AshSqlite.Types.parameterized_type(type, constraints)
    end
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
