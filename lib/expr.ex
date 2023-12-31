defmodule AshSqlite.Expr do
  @moduledoc false

  alias Ash.Filter
  alias Ash.Query.{BooleanExpression, Exists, Not, Ref}
  alias Ash.Query.Operator.IsNil

  alias Ash.Query.Function.{
    Ago,
    DateAdd,
    DateTimeAdd,
    FromNow,
    GetPath,
    If,
    Now,
    Today,
    Type
  }

  alias AshSqlite.Functions.{Fragment, ILike, Like}

  require Ecto.Query

  def dynamic_expr(query, expr, bindings, embedded? \\ false, type \\ nil)

  def dynamic_expr(query, %Filter{expression: expression}, bindings, embedded?, type) do
    dynamic_expr(query, expression, bindings, embedded?, type)
  end

  # A nil filter means "everything"
  def dynamic_expr(_, nil, _, _, _), do: true
  # A true filter means "everything"
  def dynamic_expr(_, true, _, _, _), do: true
  # A false filter means "nothing"
  def dynamic_expr(_, false, _, _, _), do: false

  def dynamic_expr(query, expression, bindings, embedded?, type) do
    do_dynamic_expr(query, expression, bindings, embedded?, type)
  end

  defp do_dynamic_expr(query, expr, bindings, embedded?, type \\ nil)

  defp do_dynamic_expr(_, {:embed, other}, _bindings, _true, _type) do
    other
  end

  defp do_dynamic_expr(query, %Not{expression: expression}, bindings, embedded?, _type) do
    new_expression = do_dynamic_expr(query, expression, bindings, embedded?, :boolean)
    Ecto.Query.dynamic(not (^new_expression))
  end

  defp do_dynamic_expr(
         query,
         %Like{arguments: [arg1, arg2], embedded?: pred_embedded?},
         bindings,
         embedded?,
         _type
       ) do
    arg1 = do_dynamic_expr(query, arg1, bindings, pred_embedded? || embedded?, :string)
    arg2 = do_dynamic_expr(query, arg2, bindings, pred_embedded? || embedded?, :string)

    Ecto.Query.dynamic(like(^arg1, ^arg2))
  end

  defp do_dynamic_expr(
         query,
         %ILike{arguments: [arg1, arg2], embedded?: pred_embedded?},
         bindings,
         embedded?,
         _type
       ) do
    arg1 = do_dynamic_expr(query, arg1, bindings, pred_embedded? || embedded?, :ci_string)
    arg2 = do_dynamic_expr(query, arg2, bindings, pred_embedded? || embedded?, :string)

    # Not ideal, but better than not having it.
    Ecto.Query.dynamic(like(fragment("LOWER(?)", ^arg1), fragment("LOWER(?)", ^arg2)))
  end

  defp do_dynamic_expr(
         query,
         %IsNil{left: left, right: right, embedded?: pred_embedded?},
         bindings,
         embedded?,
         _type
       ) do
    left_expr = do_dynamic_expr(query, left, bindings, pred_embedded? || embedded?)
    right_expr = do_dynamic_expr(query, right, bindings, pred_embedded? || embedded?, :boolean)
    Ecto.Query.dynamic(is_nil(^left_expr) == ^right_expr)
  end

  defp do_dynamic_expr(
         query,
         %Ago{arguments: [left, right], embedded?: pred_embedded?},
         bindings,
         embedded?,
         _type
       )
       when is_binary(right) or is_atom(right) do
    left = do_dynamic_expr(query, left, bindings, pred_embedded? || embedded?, :integer)

    Ecto.Query.dynamic(
      fragment("(?)", datetime_add(^DateTime.utc_now(), ^left * -1, ^to_string(right)))
    )
  end

  defp do_dynamic_expr(
         query,
         %FromNow{arguments: [left, right], embedded?: pred_embedded?},
         bindings,
         embedded?,
         _type
       )
       when is_binary(right) or is_atom(right) do
    left = do_dynamic_expr(query, left, bindings, pred_embedded? || embedded?, :integer)

    Ecto.Query.dynamic(
      fragment("(?)", datetime_add(^DateTime.utc_now(), ^left, ^to_string(right)))
    )
  end

  defp do_dynamic_expr(
         query,
         %DateTimeAdd{arguments: [datetime, amount, interval], embedded?: pred_embedded?},
         bindings,
         embedded?,
         _type
       )
       when is_binary(interval) or is_atom(interval) do
    datetime = do_dynamic_expr(query, datetime, bindings, pred_embedded? || embedded?)
    amount = do_dynamic_expr(query, amount, bindings, pred_embedded? || embedded?, :integer)
    Ecto.Query.dynamic(fragment("(?)", datetime_add(^datetime, ^amount, ^to_string(interval))))
  end

  defp do_dynamic_expr(
         query,
         %DateAdd{arguments: [date, amount, interval], embedded?: pred_embedded?},
         bindings,
         embedded?,
         _type
       )
       when is_binary(interval) or is_atom(interval) do
    date = do_dynamic_expr(query, date, bindings, pred_embedded? || embedded?)
    amount = do_dynamic_expr(query, amount, bindings, pred_embedded? || embedded?, :integer)
    Ecto.Query.dynamic(fragment("(?)", datetime_add(^date, ^amount, ^to_string(interval))))
  end

  defp do_dynamic_expr(
         query,
         %GetPath{
           arguments: [%Ref{attribute: %{type: type}}, right]
         } = get_path,
         bindings,
         embedded?,
         nil
       )
       when is_atom(type) and is_list(right) do
    if Ash.Type.embedded_type?(type) do
      type = determine_type_at_path(type, right)

      do_get_path(query, get_path, bindings, embedded?, type)
    else
      do_get_path(query, get_path, bindings, embedded?)
    end
  end

  defp do_dynamic_expr(
         query,
         %GetPath{
           arguments: [%Ref{attribute: %{type: {:array, type}}}, right]
         } = get_path,
         bindings,
         embedded?,
         nil
       )
       when is_atom(type) and is_list(right) do
    if Ash.Type.embedded_type?(type) do
      type = determine_type_at_path(type, right)
      do_get_path(query, get_path, bindings, embedded?, type)
    else
      do_get_path(query, get_path, bindings, embedded?)
    end
  end

  defp do_dynamic_expr(
         query,
         %GetPath{} = get_path,
         bindings,
         embedded?,
         type
       ) do
    do_get_path(query, get_path, bindings, embedded?, type)
  end

  # Can't support contains without also supporting case insensitive
  # strings

  # defp do_dynamic_expr(
  #        query,
  #        %Contains{arguments: [left, %Ash.CiString{} = right], embedded?: pred_embedded?},
  #        bindings,
  #        embedded?,
  #        type
  #      ) do
  #   do_dynamic_expr(
  #     query,
  #     %Fragment{
  #       embedded?: pred_embedded?,
  #       arguments: [
  #         raw: "(instr((",
  #         expr: left,
  #         raw: " COLLATE NOCASE), (",
  #         expr: right,
  #         raw: ")) > 0)"
  #       ]
  #     },
  #     bindings,
  #     embedded?,
  #     type
  #   )
  # end

  # defp do_dynamic_expr(
  #        query,
  #        %Contains{arguments: [left, right], embedded?: pred_embedded?},
  #        bindings,
  #        embedded?,
  #        type
  #      ) do
  #   do_dynamic_expr(
  #     query,
  #     %Fragment{
  #       embedded?: pred_embedded?,
  #       arguments: [
  #         raw: "(instr((",
  #         expr: left,
  #         raw: "), (",
  #         expr: right,
  #         raw: ")) > 0)"
  #       ]
  #     },
  #     bindings,
  #     embedded?,
  #     type
  #   )
  # end

  defp do_dynamic_expr(
         query,
         %If{arguments: [condition, when_true, when_false], embedded?: pred_embedded?},
         bindings,
         embedded?,
         type
       ) do
    [condition_type, when_true_type, when_false_type] =
      case AshSqlite.Types.determine_types(If, [condition, when_true, when_false]) do
        [condition_type, when_true] ->
          [condition_type, when_true, nil]

        [condition_type, when_true, when_false] ->
          [condition_type, when_true, when_false]
      end
      |> case do
        [condition_type, nil, nil] ->
          [condition_type, type, type]

        [condition_type, when_true, nil] ->
          [condition_type, when_true, type]

        [condition_type, nil, when_false] ->
          [condition_type, type, when_false]

        [condition_type, when_true, when_false] ->
          [condition_type, when_true, when_false]
      end

    condition =
      do_dynamic_expr(query, condition, bindings, pred_embedded? || embedded?, condition_type)

    when_true =
      do_dynamic_expr(query, when_true, bindings, pred_embedded? || embedded?, when_true_type)

    when_false =
      do_dynamic_expr(
        query,
        when_false,
        bindings,
        pred_embedded? || embedded?,
        when_false_type
      )

    do_dynamic_expr(
      query,
      %Fragment{
        embedded?: pred_embedded?,
        arguments: [
          raw: "(CASE WHEN ",
          casted_expr: condition,
          raw: " THEN ",
          casted_expr: when_true,
          raw: " ELSE ",
          casted_expr: when_false,
          raw: " END)"
        ]
      },
      bindings,
      embedded?,
      type
    )
  end

  # Wow, even this doesn't work, because of course it doesn't.
  # Doing string joining properly requires a recursive "if not empty" check
  # that honestly I don't have the energy to do right now.
  # There are commented out tests for this in the calculation tests, make sure those pass,
  # whoever feels like fixing this.
  # defp do_dynamic_expr(
  #        _query,
  #        %StringJoin{arguments: [values | _], embedded?: _pred_embedded?} = string_join,
  #        _bindings,
  #        _embedded?,
  #        _type
  #      )
  #      when not is_list(values) do
  #   raise "SQLite can only join literal lists, not dynamic values. i.e `string_join([foo, bar])`,
  #    but not `string_join(something)`. Got #{inspect(string_join)}"
  # end

  # defp do_dynamic_expr(
  #        query,
  #        %StringJoin{arguments: [values, joiner], embedded?: pred_embedded?},
  #        bindings,
  #        embedded?,
  #        type
  #      ) do
  #   # Not optimal, but it works
  #   last_value = :lists.last(values)

  #   values =
  #     values
  #     |> :lists.droplast()
  #     |> Enum.map(&{:not_last, &1})
  #     |> Enum.concat([{:last, last_value}])

  #   do_dynamic_expr(
  #     query,
  #     %Fragment{
  #       embedded?: pred_embedded?,
  #       arguments:
  #         Enum.reduce(values, [raw: "("], fn
  #           {:last, value}, acc ->
  #             acc ++
  #               [
  #                 raw: "COALESCE(",
  #                 expr: value,
  #                 raw: ", '')"
  #               ]

  #           {:not_last, value}, acc ->
  #             acc ++
  #               [
  #                 raw: "(CASE ",
  #                 expr: value,
  #                 raw: " WHEN NULL THEN '' ELSE ",
  #                 expr: value,
  #                 raw: " || ",
  #                 expr: joiner,
  #                 raw: " END) || "
  #               ]
  #         end)
  #         |> Enum.concat(raw: ")")
  #     },
  #     bindings,
  #     embedded?,
  #     type
  #   )
  # end

  # defp do_dynamic_expr(
  #        query,
  #        %StringJoin{arguments: [values], embedded?: pred_embedded?},
  #        bindings,
  #        embedded?,
  #        type
  #      ) do
  #   do_dynamic_expr(
  #     query,
  #     %Fragment{
  #       embedded?: pred_embedded?,
  #       arguments:
  #         Enum.reduce(values, {[raw: "("], true}, fn value, {acc, first?} ->
  #           add =
  #             if first? do
  #               [expr: value]
  #             else
  #               [raw: " || COALESCE(", expr: value, raw: ", '')"]
  #             end

  #           {acc ++ add, false}
  #         end)
  #         |> elem(0)
  #         |> Enum.concat(raw: ")")
  #     },
  #     bindings,
  #     embedded?,
  #     type
  #   )
  # end

  # Sorry :(
  # This is bad to do, but is the only reasonable way I could find.
  defp do_dynamic_expr(
         query,
         %Fragment{arguments: arguments, embedded?: pred_embedded?},
         bindings,
         embedded?,
         _type
       ) do
    arguments =
      case arguments do
        [{:raw, _} | _] ->
          arguments

        arguments ->
          [{:raw, ""} | arguments]
      end

    arguments =
      case List.last(arguments) do
        nil ->
          arguments

        {:raw, _} ->
          arguments

        _ ->
          arguments ++ [{:raw, ""}]
      end

    {params, fragment_data, _} =
      Enum.reduce(arguments, {[], [], 0}, fn
        {:raw, str}, {params, fragment_data, count} ->
          {params, [{:raw, str} | fragment_data], count}

        {:casted_expr, dynamic}, {params, fragment_data, count} ->
          {item, params, count} =
            {{:^, [], [count]}, [{dynamic, :any} | params], count + 1}

          {params, [{:expr, item} | fragment_data], count}

        {:expr, expr}, {params, fragment_data, count} ->
          dynamic = do_dynamic_expr(query, expr, bindings, pred_embedded? || embedded?)

          type =
            if is_binary(expr) do
              :string
            else
              :any
            end

          {item, params, count} =
            {{:^, [], [count]}, [{dynamic, type} | params], count + 1}

          {params, [{:expr, item} | fragment_data], count}
      end)

    %Ecto.Query.DynamicExpr{
      fun: fn _query ->
        {{:fragment, [], Enum.reverse(fragment_data)}, Enum.reverse(params), [], %{}}
      end,
      binding: [],
      file: __ENV__.file,
      line: __ENV__.line
    }
  end

  defp do_dynamic_expr(
         query,
         %BooleanExpression{op: op, left: left, right: right},
         bindings,
         embedded?,
         _type
       ) do
    left_expr = do_dynamic_expr(query, left, bindings, embedded?, :boolean)
    right_expr = do_dynamic_expr(query, right, bindings, embedded?, :boolean)

    case op do
      :and ->
        Ecto.Query.dynamic(^left_expr and ^right_expr)

      :or ->
        Ecto.Query.dynamic(^left_expr or ^right_expr)
    end
  end

  defp do_dynamic_expr(
         query,
         %Ash.Query.Function.Minus{arguments: [arg], embedded?: pred_embedded?},
         bindings,
         embedded?,
         type
       ) do
    [determined_type] = AshSqlite.Types.determine_types(Ash.Query.Function.Minus, [arg])

    expr =
      do_dynamic_expr(query, arg, bindings, pred_embedded? || embedded?, determined_type || type)

    Ecto.Query.dynamic(-(^expr))
  end

  # Honestly we need to either 1. not type cast or 2. build in type compatibility concepts
  # instead of `:same` we need an `ANY COMPATIBLE` equivalent.
  @cast_operands_for [:<>]

  defp do_dynamic_expr(
         query,
         %mod{
           __predicate__?: _,
           left: left,
           right: right,
           embedded?: pred_embedded?,
           operator: operator
         },
         bindings,
         embedded?,
         type
       ) do
    [left_type, right_type] =
      mod
      |> AshSqlite.Types.determine_types([left, right])

    left_expr =
      if left_type && operator in @cast_operands_for do
        left_expr = do_dynamic_expr(query, left, bindings, pred_embedded? || embedded?)

        type_expr(left_expr, left_type)
      else
        do_dynamic_expr(query, left, bindings, pred_embedded? || embedded?, left_type)
      end

    right_expr =
      if right_type && operator in @cast_operands_for do
        right_expr = do_dynamic_expr(query, right, bindings, pred_embedded? || embedded?)
        type_expr(right_expr, right_type)
      else
        do_dynamic_expr(query, right, bindings, pred_embedded? || embedded?, right_type)
      end

    case operator do
      :== ->
        Ecto.Query.dynamic(^left_expr == ^right_expr)

      :!= ->
        Ecto.Query.dynamic(^left_expr != ^right_expr)

      :> ->
        Ecto.Query.dynamic(^left_expr > ^right_expr)

      :< ->
        Ecto.Query.dynamic(^left_expr < ^right_expr)

      :>= ->
        Ecto.Query.dynamic(^left_expr >= ^right_expr)

      :<= ->
        Ecto.Query.dynamic(^left_expr <= ^right_expr)

      :in ->
        Ecto.Query.dynamic(^left_expr in ^right_expr)

      :+ ->
        Ecto.Query.dynamic(^left_expr + ^right_expr)

      :- ->
        Ecto.Query.dynamic(^left_expr - ^right_expr)

      :/ ->
        Ecto.Query.dynamic(type(^left_expr, :decimal) / type(^right_expr, :decimal))

      :* ->
        Ecto.Query.dynamic(^left_expr * ^right_expr)

      :<> ->
        do_dynamic_expr(
          query,
          %Fragment{
            embedded?: pred_embedded?,
            arguments: [
              raw: "(",
              casted_expr: left_expr,
              raw: " || ",
              casted_expr: right_expr,
              raw: ")"
            ]
          },
          bindings,
          embedded?,
          type
        )

      :|| ->
        do_dynamic_expr(
          query,
          %Fragment{
            embedded?: pred_embedded?,
            arguments: [
              raw: "(CASE WHEN (",
              casted_expr: left_expr,
              raw: " == FALSE OR ",
              casted_expr: left_expr,
              raw: " IS NULL) THEN ",
              casted_expr: right_expr,
              raw: " ELSE ",
              casted_expr: left_expr,
              raw: "END)"
            ]
          },
          bindings,
          embedded?,
          type
        )

      :&& ->
        do_dynamic_expr(
          query,
          %Fragment{
            embedded?: pred_embedded?,
            arguments: [
              raw: "(CASE WHEN (",
              casted_expr: left_expr,
              raw: " == FALSE OR ",
              casted_expr: left_expr,
              raw: " IS NULL) THEN ",
              casted_expr: left_expr,
              raw: " ELSE ",
              casted_expr: right_expr,
              raw: "END)"
            ]
          },
          bindings,
          embedded?,
          type
        )

      other ->
        raise "Operator not implemented #{other}"
    end
  end

  defp do_dynamic_expr(query, %MapSet{} = mapset, bindings, embedded?, type) do
    do_dynamic_expr(query, Enum.to_list(mapset), bindings, embedded?, type)
  end

  defp do_dynamic_expr(
         query,
         %Ash.CiString{string: string},
         bindings,
         embedded?,
         type
       ) do
    string = do_dynamic_expr(query, string, bindings, embedded?)

    do_dynamic_expr(
      query,
      %Fragment{
        embedded?: embedded?,
        arguments: [
          raw: "(",
          casted_expr: string,
          raw: "collate nocase)"
        ]
      },
      bindings,
      embedded?,
      type
    )
  end

  defp do_dynamic_expr(
         query,
         %Ref{
           attribute: %Ash.Query.Calculation{} = calculation,
           relationship_path: [],
           resource: resource
         },
         bindings,
         embedded?,
         _type
       ) do
    calculation = %{calculation | load: calculation.name}

    type =
      AshSqlite.Types.parameterized_type(
        calculation.type,
        Map.get(calculation, :constraints, [])
      )

    case Ash.Filter.hydrate_refs(
           calculation.module.expression(calculation.opts, calculation.context),
           %{
             resource: resource,
             calculations: %{},
             public?: false
           }
         ) do
      {:ok, expression} ->
        do_dynamic_expr(
          query,
          expression,
          bindings,
          embedded?,
          type
        )

      {:error, error} ->
        raise """
        Failed to hydrate references in #{inspect(calculation.module.expression(calculation.opts, calculation.context))}

        #{inspect(error)}
        """
    end
  end

  defp do_dynamic_expr(
         _query,
         %Ref{
           attribute: %Ash.Resource.Calculation{} = calculation
         },
         _bindings,
         _embedded?,
         _type
       ) do
    raise "cannot build expression from resource calculation! #{calculation.name}"
  end

  defp do_dynamic_expr(
         query,
         %Ref{
           attribute: %Ash.Query.Calculation{} = calculation,
           relationship_path: relationship_path
         } = ref,
         bindings,
         embedded?,
         _type
       ) do
    binding_to_replace =
      Enum.find_value(bindings.bindings, fn {i, binding} ->
        if binding.path == relationship_path do
          i
        end
      end)

    if is_nil(binding_to_replace) do
      raise """
      Error building calculation reference: #{inspect(relationship_path)} is not available in bindings.

      In reference: #{ref}
      """
    end

    temp_bindings =
      bindings.bindings
      |> Map.delete(0)
      |> Map.update!(binding_to_replace, &Map.merge(&1, %{path: [], type: :root}))

    type =
      AshSqlite.Types.parameterized_type(
        calculation.type,
        Map.get(calculation, :constraints, [])
      )

    case Ash.Filter.hydrate_refs(
           calculation.module.expression(calculation.opts, calculation.context),
           %{
             resource: ref.resource,
             calculations: %{},
             public?: false
           }
         ) do
      {:ok, hydrated} ->
        expr =
          do_dynamic_expr(
            query,
            hydrated,
            %{bindings | bindings: temp_bindings},
            embedded?,
            type
          )

        type_expr(expr, type)

      _ ->
        raise "Failed to hydrate references in #{inspect(calculation.module.expression(calculation.opts, calculation.context))}"
    end
  end

  defp do_dynamic_expr(
         query,
         %Type{arguments: [arg1, arg2, constraints]},
         bindings,
         embedded?,
         _type
       ) do
    arg2 = Ash.Type.get_type(arg2)
    arg1 = maybe_uuid_to_binary(arg2, arg1, arg1)
    type = AshSqlite.Types.parameterized_type(arg2, constraints)

    query
    |> do_dynamic_expr(arg1, bindings, embedded?, type)
    |> type_expr(type)
  end

  defp do_dynamic_expr(
         query,
         %Now{embedded?: pred_embedded?},
         bindings,
         embedded?,
         type
       ) do
    do_dynamic_expr(
      query,
      DateTime.utc_now(),
      bindings,
      embedded? || pred_embedded?,
      type
    )
  end

  defp do_dynamic_expr(
         query,
         %Today{embedded?: pred_embedded?},
         bindings,
         embedded?,
         type
       ) do
    do_dynamic_expr(
      query,
      Date.utc_today(),
      bindings,
      embedded? || pred_embedded?,
      type
    )
  end

  defp do_dynamic_expr(
         query,
         %Ash.Query.Parent{expr: expr},
         bindings,
         embedded?,
         type
       ) do
    if !bindings[:parent_bindings] do
      raise "Used `parent/1` without parent context. AshSqlite is not capable of supporting `parent/1` in relationship where clauses yet."
    end

    parent? = Map.get(bindings.parent_bindings, :parent_is_parent_as?, true)

    do_dynamic_expr(
      %{
        query
        | __ash_bindings__: Map.put(bindings.parent_bindings, :parent?, parent?)
      },
      expr,
      bindings,
      embedded?,
      type
    )
  end

  defp do_dynamic_expr(
         query,
         %Exists{at_path: at_path, path: [first | rest], expr: expr},
         bindings,
         _embedded?,
         _type
       ) do
    resource = Ash.Resource.Info.related(query.__ash_bindings__.resource, at_path)
    first_relationship = Ash.Resource.Info.relationship(resource, first)

    last_relationship =
      Enum.reduce(rest, first_relationship, fn name, relationship ->
        Ash.Resource.Info.relationship(relationship.destination, name)
      end)

    {:ok, expr} =
      Ash.Filter.hydrate_refs(expr, %{
        resource: last_relationship.destination,
        parent_stack: [
          query.__ash_bindings__.resource
          | query.__ash_bindings__[:parent_resources] || []
        ],
        calculations: %{},
        public?: false
      })

    filter =
      %Ash.Filter{expression: expr, resource: first_relationship.destination}
      |> nest_expression(rest)

    {:ok, source} =
      AshSqlite.Join.maybe_get_resource_query(
        first_relationship.destination,
        first_relationship,
        query,
        [first_relationship.name]
      )

    {:ok, filtered} =
      source
      |> set_parent_path(query)
      |> AshSqlite.DataLayer.filter(
        filter,
        first_relationship.destination,
        no_this?: true
      )

    free_binding = filtered.__ash_bindings__.current

    exists_query =
      cond do
        Map.get(first_relationship, :manual) ->
          {module, opts} = first_relationship.manual

          [pkey_attr | _] = Ash.Resource.Info.primary_key(first_relationship.destination)

          pkey_attr = Ash.Resource.Info.attribute(first_relationship.destination, pkey_attr)

          source_ref =
            ref_binding(
              %Ref{
                attribute: pkey_attr,
                relationship_path: at_path,
                resource: resource
              },
              bindings
            )

          {:ok, subquery} =
            module.ash_sqlite_subquery(
              opts,
              source_ref,
              0,
              filtered
            )

          subquery

        first_relationship.type == :many_to_many ->
          source_ref =
            ref_binding(
              %Ref{
                attribute:
                  Ash.Resource.Info.attribute(resource, first_relationship.source_attribute),
                relationship_path: at_path,
                resource: resource
              },
              bindings
            )

          through_relationship =
            Ash.Resource.Info.relationship(resource, first_relationship.join_relationship)

          through_bindings =
            query
            |> Map.delete(:__ash_bindings__)
            |> AshSqlite.DataLayer.default_bindings(
              query.__ash_bindings__.resource,
              query.__ash_bindings__.context
            )
            |> Map.get(:__ash_bindings__)
            |> Map.put(:bindings, %{
              free_binding => %{path: [], source: first_relationship.through, type: :root}
            })

          {:ok, through} =
            AshSqlite.Join.maybe_get_resource_query(
              first_relationship.through,
              through_relationship,
              query,
              [first_relationship.join_relationship],
              through_bindings,
              nil,
              false
            )

          Ecto.Query.from(destination in filtered,
            join: through in ^through,
            as: ^free_binding,
            on:
              field(through, ^first_relationship.destination_attribute_on_join_resource) ==
                field(destination, ^first_relationship.destination_attribute),
            on:
              field(parent_as(^source_ref), ^first_relationship.source_attribute) ==
                field(through, ^first_relationship.source_attribute_on_join_resource)
          )

        Map.get(first_relationship, :no_attributes?) ->
          filtered

        true ->
          source_ref =
            ref_binding(
              %Ref{
                attribute:
                  Ash.Resource.Info.attribute(resource, first_relationship.source_attribute),
                relationship_path: at_path,
                resource: resource
              },
              bindings
            )

          Ecto.Query.from(destination in filtered,
            where:
              field(parent_as(^source_ref), ^first_relationship.source_attribute) ==
                field(destination, ^first_relationship.destination_attribute)
          )
      end

    exists_query =
      exists_query
      |> Ecto.Query.exclude(:select)
      |> Ecto.Query.select(1)

    Ecto.Query.dynamic(exists(Ecto.Query.subquery(exists_query)))
  end

  defp do_dynamic_expr(
         query,
         %Ref{
           attribute: %Ash.Resource.Attribute{
             name: name,
             type: attr_type,
             constraints: constraints
           }
         } = ref,
         bindings,
         _embedded?,
         expr_type
       ) do
    ref_binding = ref_binding(ref, bindings)

    if is_nil(ref_binding) do
      raise "Error while building reference: #{inspect(ref)}"
    end

    constraints =
      if attr_type do
        constraints
      end

    case AshSqlite.Types.parameterized_type(attr_type || expr_type, constraints) do
      nil ->
        if query.__ash_bindings__[:parent?] do
          Ecto.Query.dynamic(field(parent_as(^ref_binding), ^name))
        else
          Ecto.Query.dynamic(field(as(^ref_binding), ^name))
        end

      type ->
        dynamic =
          if query.__ash_bindings__[:parent?] do
            Ecto.Query.dynamic(field(parent_as(^ref_binding), ^name))
          else
            Ecto.Query.dynamic(field(as(^ref_binding), ^name))
          end

        type_expr(dynamic, type)
    end
  end

  defp do_dynamic_expr(query, value, bindings, embedded?, _type)
       when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, value} ->
      {key, do_dynamic_expr(query, value, bindings, embedded?)}
    end)
  end

  defp do_dynamic_expr(query, other, bindings, true, type) do
    if other && is_atom(other) && !is_boolean(other) do
      to_string(other)
    else
      if Ash.Filter.TemplateHelpers.expr?(other) do
        if is_list(other) do
          list_expr(query, other, bindings, true, type)
        else
          raise "Unsupported expression in AshSqlite query: #{inspect(other)}"
        end
      else
        maybe_sanitize_list(query, other, bindings, true, type)
      end
    end
  end

  defp do_dynamic_expr(query, value, bindings, embedded?, {:in, type}) when is_list(value) do
    list_expr(query, value, bindings, embedded?, {:array, type})
  end

  defp do_dynamic_expr(query, value, bindings, embedded?, type)
       when not is_nil(value) and is_atom(value) and not is_boolean(value) do
    do_dynamic_expr(query, to_string(value), bindings, embedded?, type)
  end

  defp do_dynamic_expr(query, value, bindings, false, type) when type == nil or type == :any do
    if is_list(value) do
      list_expr(query, value, bindings, false, type)
    else
      maybe_sanitize_list(query, value, bindings, true, type)
    end
  end

  defp do_dynamic_expr(query, value, bindings, false, type) do
    if Ash.Filter.TemplateHelpers.expr?(value) do
      if is_list(value) do
        list_expr(query, value, bindings, false, type)
      else
        raise "Unsupported expression in AshSqlite query: #{inspect(value)}"
      end
    else
      case maybe_sanitize_list(query, value, bindings, true, type) do
        ^value ->
          type_expr(value, type)

        value ->
          value
      end
    end
  end

  defp type_expr(expr, type) do
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

  defp list_expr(query, value, bindings, embedded?, type) do
    type =
      case type do
        {:array, type} -> type
        {:in, type} -> type
        _ -> nil
      end

    {params, exprs, _} =
      Enum.reduce(value, {[], [], 0}, fn value, {params, data, count} ->
        case do_dynamic_expr(query, value, bindings, embedded?, type) do
          %Ecto.Query.DynamicExpr{} = dynamic ->
            result =
              Ecto.Query.Builder.Dynamic.partially_expand(
                :select,
                query,
                dynamic,
                params,
                count
              )

            expr = elem(result, 0)
            new_params = elem(result, 1)
            new_count = result |> Tuple.to_list() |> List.last()

            {new_params, [expr | data], new_count}

          other ->
            {params, [other | data], count}
        end
      end)

    %Ecto.Query.DynamicExpr{
      fun: fn _query ->
        {Enum.reverse(exprs), Enum.reverse(params), [], []}
      end,
      binding: [],
      file: __ENV__.file,
      line: __ENV__.line
    }
  end

  defp maybe_uuid_to_binary({:array, type}, value, _original_value) when is_list(value) do
    Enum.map(value, &maybe_uuid_to_binary(type, &1, &1))
  end

  defp maybe_uuid_to_binary(type, value, original_value)
       when type in [
              Ash.Type.UUID.EctoType,
              :uuid
            ] and is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, encoded} -> encoded
      _ -> original_value
    end
  end

  defp maybe_uuid_to_binary(_type, _value, original_value), do: original_value

  defp maybe_sanitize_list(query, value, bindings, embedded?, type) do
    if is_list(value) do
      Enum.map(value, &do_dynamic_expr(query, &1, bindings, embedded?, type))
    else
      value
    end
  end

  defp ref_binding(%{attribute: %Ash.Resource.Attribute{}} = ref, bindings) do
    Enum.find_value(bindings.bindings, fn {binding, data} ->
      data.path == ref.relationship_path && data.type in [:inner, :left, :root] && binding
    end)
  end

  defp do_get_path(
         query,
         %GetPath{arguments: [left, right], embedded?: pred_embedded?},
         bindings,
         embedded?,
         type \\ nil
       ) do
    path = "$." <> Enum.join(right, ".")

    expr =
      do_dynamic_expr(
        query,
        %Fragment{
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
        embedded?
      )

    if type do
      type_expr(expr, type)
    else
      expr
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

  defp set_parent_path(query, parent) do
    # This is a stupid name. Its actually the path we *remove* when stepping up a level. I.e the child's path
    Map.update!(query, :__ash_bindings__, fn ash_bindings ->
      ash_bindings
      |> Map.put(:parent_bindings, parent.__ash_bindings__)
      |> Map.put(:parent_resources, [
        parent.__ash_bindings__.resource | parent.__ash_bindings__[:parent_resources] || []
      ])
    end)
  end

  defp nest_expression(expression, relationship_path) do
    case expression do
      {key, value} when is_atom(key) ->
        {key, nest_expression(value, relationship_path)}

      %Not{expression: expression} = not_expr ->
        %{not_expr | expression: nest_expression(expression, relationship_path)}

      %BooleanExpression{left: left, right: right} = expression ->
        %{
          expression
          | left: nest_expression(left, relationship_path),
            right: nest_expression(right, relationship_path)
        }

      %{__operator__?: true, left: left, right: right} = op ->
        left = nest_expression(left, relationship_path)
        right = nest_expression(right, relationship_path)
        %{op | left: left, right: right}

      %Ref{} = ref ->
        add_to_ref_path(ref, relationship_path)

      %{__function__?: true, arguments: args} = func ->
        %{func | arguments: Enum.map(args, &nest_expression(&1, relationship_path))}

      %Ash.Query.Exists{} = exists ->
        %{exists | at_path: relationship_path ++ exists.at_path}

      %Ash.Query.Parent{} = parent ->
        parent

      %Ash.Query.Call{args: args} = call ->
        %{call | args: Enum.map(args, &nest_expression(&1, relationship_path))}

      %Ash.Filter{expression: expression} = filter ->
        %{filter | expression: nest_expression(expression, relationship_path)}

      other ->
        other
    end
  end

  defp add_to_ref_path(%Ref{relationship_path: relationship_path} = ref, to_add) do
    %{ref | relationship_path: to_add ++ relationship_path}
  end
end
