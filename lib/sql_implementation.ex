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

  # Handle comparisons involving map values - SQLite has no structural JSON
  # equality, so we compile the literal map into a conjunction of json_type/
  # json_extract checks. Comparing serialized JSON text is not enough: the
  # stored key order can differ from the encoded literal's key order, which
  # made `==` miss rows and `!=` return rows it should have excluded.
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

  # `is_distinct_from` is the NULL-safe form of `!=`, and Ash emits it in place of `!=` whenever
  # either side can be nil (see `Ash.Query.Function.IsDistinctFrom.new/1`). It needs the same
  # JSON treatment as the two clauses above, and without it a map reaches the driver as a bare
  # Elixir term and is rejected: `(Exqlite.Error) unsupported type: %{...}`. The clearest way to
  # see it is one resource with two `:map` attributes, where only `allow_nil?` differs - the
  # `allow_nil? false` one takes `!=` and updates, the nullable one takes `is_distinct_from` and
  # raises. `update_timestamp` builds exactly this comparison, so any atomic update of a nullable
  # map attribute is affected.
  def expr(
        query,
        %Ash.Query.Function.IsDistinctFrom{
          arguments: [left, right],
          embedded?: pred_embedded?
        },
        bindings,
        embedded?,
        acc,
        type
      )
      when is_non_struct_map(left) or is_non_struct_map(right) do
    handle_map_comparison(
      query,
      :is_distinct_from,
      left,
      right,
      pred_embedded?,
      bindings,
      embedded?,
      acc,
      type
    )
  end

  def expr(
        query,
        %Ash.Query.Function.IsNotDistinctFrom{
          arguments: [left, right],
          embedded?: pred_embedded?
        },
        bindings,
        embedded?,
        acc,
        type
      )
      when is_non_struct_map(left) or is_non_struct_map(right) do
    handle_map_comparison(
      query,
      :is_not_distinct_from,
      left,
      right,
      pred_embedded?,
      bindings,
      embedded?,
      acc,
      type
    )
  end

  # The clauses above compile a map that is an OPERAND of a comparison, and `list_expr/6`
  # below JSON-encodes a map that is an ELEMENT of a list. A map in any other position is still
  # handed to the driver as a bare Elixir term, and rejected:
  #
  #     ** (Exqlite.Error) unsupported type: %{"k" => "v"}
  #     SELECT ... FROM "devices" AS d0 WHERE ((json(d0."entity") = json(?)))
  #
  # AshSql renders a plain map specially only inside a `select` sub-expression, or inside an
  # `update` / `aggregate` when the map CONTAINS an expression; every other position falls through
  # to binding the map itself as a parameter. That covers a map used as a fragment argument, as a
  # branch of an `if`, or anywhere else an expression can nest.
  #
  # The map is data, so it is bound as its JSON text. `Jason.encode!/1` is what Ecto's SQLite
  # adapter dumps for a `:map` column, so a map rendered here is byte-identical to the same map
  # stored by an INSERT. (Comparison OPERANDS don't rely on that byte-identity - they are compiled
  # structurally by `handle_map_comparison/9` so stored key order can't affect the result.)
  #
  # A map that contains an expression is left alone: its values are not data, so they cannot be
  # encoded, and AshSql's own handling of that case is unchanged.
  def expr(query, value, bindings, embedded?, acc, _type)
      when is_non_struct_map(value) do
    if bindings[:location] == :select or Ash.Expr.expr?(value) do
      :error
    else
      {expr, acc} =
        AshSql.Expr.dynamic_expr(query, Jason.encode!(value), bindings, embedded?, :string, acc)

      {:ok, expr, acc}
    end
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

  # SQLite has no `ARRAY[...]` constructor, so the `ARRAY[...]` / `array_to_json(ARRAY[...])`
  # rendering AshSql falls back to is a syntax error here:
  #
  #     ** (Exqlite.Error) near "[?,?]": syntax error
  #     UPDATE "visual_machines" AS v0 SET ..., "nodes" = ARRAY[?,?]
  #
  # `json_array(...)` is the equivalent, and the element treatment is chosen to match what the
  # data layer already stores for the same column. Ecto's SQLite adapter dumps an
  # `{:array, :map}` field by JSON-encoding each element and then JSON-encoding the list, so the
  # column holds a JSON array of JSON STRINGS:
  #
  #     ["{\"id\":\"n1\"}","{\"id\":\"n2\"}"]
  #
  # `json_array(?, ?)` with each parameter bound to `Jason.encode!(element)` produces exactly
  # that, byte for byte, which is what makes the value round-trip through the loader and makes
  # the `is_distinct_from` comparison against the column meaningful (a no-op write compares
  # equal and does not bump `updated_at`).
  #
  # When the expected type is a JSON value rather than an array column (`:map` / `:json` /
  # `:jsonb`, the case AshSql renders with `array_to_json`), the elements are JSON VALUES rather
  # than strings, so they go through `json(...)`.
  @impl true
  def list_expr(query, value, bindings, embedded?, acc, type) do
    json_value? = type in [:map, :jsonb, :json]

    elements =
      value
      |> Enum.map(&list_element(&1, json_value?))
      |> Enum.intersperse(raw: ",")
      |> List.flatten()

    {expr, acc} =
      AshSql.Expr.dynamic_expr(
        query,
        %Ash.Query.Function.Fragment{
          embedded?: embedded?,
          arguments: [raw: "json_array("] ++ elements ++ [raw: ")"]
        },
        bindings,
        embedded?,
        type,
        acc
      )

    {:ok, expr, acc}
  end

  # A plain map or list is data, and it is bound as its JSON text. Anything else (an expression,
  # a column reference, a scalar) is rendered as itself.
  defp list_element(item, json_value?) when is_list(item), do: encoded_element(item, json_value?)

  defp list_element(item, json_value?) when is_map(item) and not is_struct(item),
    do: encoded_element(item, json_value?)

  defp list_element(item, _json_value?), do: [expr: item]

  defp encoded_element(item, true), do: [raw: "json(", expr: Jason.encode!(item), raw: ")"]
  defp encoded_element(item, false), do: [expr: Jason.encode!(item)]

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
    left_literal? = literal_map?(left)
    right_literal? = literal_map?(right)

    cond do
      left_literal? and right_literal? ->
        equal? = normalize_json_value(left) == normalize_json_value(right)

        result =
          if operator in [:==, :is_not_distinct_from], do: equal?, else: not equal?

        {:ok, Ecto.Query.dynamic(type(^result, :boolean)), acc}

      left_literal? ->
        structural_map_comparison(
          query,
          operator,
          right,
          left,
          pred_embedded?,
          bindings,
          embedded?,
          acc,
          type
        )

      right_literal? ->
        structural_map_comparison(
          query,
          operator,
          left,
          right,
          pred_embedded?,
          bindings,
          embedded?,
          acc,
          type
        )

      true ->
        :error
    end
  end

  defp structural_map_comparison(
         query,
         operator,
         value,
         map,
         pred_embedded?,
         bindings,
         embedded?,
         acc,
         type
       ) do
    {value_expr, acc} =
      AshSql.Expr.dynamic_expr(query, value, bindings, pred_embedded? || embedded?, nil, acc)

    match = structural_match(value_expr, normalize_json_value(map))

    # `structural_match/2` is built from null-safe `IS` checks, so it is
    # always true or false - a NULL value simply fails to match. That is
    # exactly the semantics the distinct-from operators want (NULL is
    # distinct from every map), so they use the match directly. `==`/`!=`
    # instead preserve SQL NULL comparison semantics - a NULL value
    # compares as NULL - like the other operator translations.
    result =
      case operator do
        :is_not_distinct_from ->
          match

        :is_distinct_from ->
          Ecto.Query.dynamic(not (^match))

        :== ->
          Ecto.Query.dynamic(
            fragment("(CASE WHEN (?) IS NULL THEN NULL ELSE ? END)", ^value_expr, ^match)
          )

        :!= ->
          Ecto.Query.dynamic(
            fragment(
              "(CASE WHEN (?) IS NULL THEN NULL ELSE ? END)",
              ^value_expr,
              ^Ecto.Query.dynamic(not (^match))
            )
          )
      end

    result =
      if boolean_type?(type) do
        Ecto.Query.dynamic(type(^result, :boolean))
      else
        result
      end

    {:ok, result, acc}
  end

  # Every check uses SQLite's null-safe `IS` comparison so the match is
  # always true or false, never NULL - otherwise a missing key would make
  # `!=` comparisons evaluate to NULL and wrongly filter rows out.
  defp structural_match(expr, value) when is_map(value) do
    base =
      Ecto.Query.dynamic(
        fragment("json_type(?) IS 'object'", ^expr) and
          fragment("(SELECT count(*) FROM json_each(?)) IS ?", ^expr, ^map_size(value))
      )

    Enum.reduce(value, base, fn {key, child_value}, match ->
      child = access_json_key(expr, key)
      Ecto.Query.dynamic(^match and ^structural_match(child, child_value))
    end)
  end

  defp structural_match(expr, value) when is_list(value) do
    base =
      Ecto.Query.dynamic(
        fragment("json_type(?) IS 'array'", ^expr) and
          fragment("json_array_length(?) IS ?", ^expr, ^length(value))
      )

    value
    |> Enum.with_index()
    |> Enum.reduce(base, fn {child_value, index}, match ->
      child = Ecto.Query.dynamic(fragment("(? -> ?)", ^expr, ^index))
      Ecto.Query.dynamic(^match and ^structural_match(child, child_value))
    end)
  end

  defp structural_match(expr, nil) do
    Ecto.Query.dynamic(fragment("json_type(?) IS 'null'", ^expr))
  end

  defp structural_match(expr, true) do
    Ecto.Query.dynamic(fragment("json_type(?) IS 'true'", ^expr))
  end

  defp structural_match(expr, false) do
    Ecto.Query.dynamic(fragment("json_type(?) IS 'false'", ^expr))
  end

  defp structural_match(expr, value) when is_number(value) do
    Ecto.Query.dynamic(
      fragment("IFNULL(json_type(?), '') IN ('integer', 'real')", ^expr) and
        fragment("(? ->> '$') IS ?", ^expr, ^value)
    )
  end

  defp structural_match(expr, value) when is_binary(value) do
    Ecto.Query.dynamic(
      fragment("json_type(?) IS 'text'", ^expr) and
        fragment("(? ->> '$') IS ?", ^expr, ^value)
    )
  end

  # `->` treats a text right-hand side as an object label, which binds the
  # key safely as a parameter. Keys that SQLite would misparse (leading `$`
  # is read as a JSON path, quotes/backslashes break label parsing, and ''
  # is a path error) go through json_each instead, which matches keys
  # byte-for-byte. json_quote rebuilds scalar members as JSON text so the
  # recursive checks see the same shape `->` produces.
  defp access_json_key(expr, key) do
    if key != "" and not String.starts_with?(key, "$") and
         not String.contains?(key, ["\"", "\\"]) do
      Ecto.Query.dynamic(fragment("(? -> ?)", ^expr, ^key))
    else
      Ecto.Query.dynamic(
        fragment(
          "(SELECT CASE WHEN json_each.type IN ('object', 'array') THEN json_each.value ELSE json_quote(json_each.value) END FROM json_each(?) WHERE json_each.key IS ?)",
          ^expr,
          ^key
        )
      )
    end
  end

  # Round-tripping through JSON gives the same view of the value the
  # database has: string keys, and no atoms or structs.
  defp normalize_json_value(value) do
    value
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp literal_map?(value) do
    is_map(value) and not is_struct(value) and not Ash.Expr.expr?(value)
  end

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
    path = encode_json_path(right)

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

  defp encode_json_path(segments) do
    Enum.reduce(segments, "$", fn segment, path -> path <> encode_json_path_segment(segment) end)
  end

  defp encode_json_path_segment(segment) when is_integer(segment) do
    "[" <> Integer.to_string(segment) <> "]"
  end

  defp encode_json_path_segment(segment) do
    escaped =
      segment
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    ".\"" <> escaped <> "\""
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
