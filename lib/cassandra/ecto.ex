defmodule Cassandra.Ecto do

  alias Ecto.Query.BooleanExpr

  @identifier ~r/[a-zA-Z][a-zA-Z0-9_]*/
  @unquoted_name ~r/[a-zA-Z_0-9]{1,48}/
  @binary_operators_map %{
    :== => "=",
    :<  => "<",
    :>  => ">",
    :<= => "<=",
    :>= => ">=",
    :!= => "!=",
  }
  @binary_operators Map.keys(@binary_operators_map)

  def to_cql(%{sources: sources} = query) do
    assemble([
      select(query, sources),
      from(query, sources),
      where(query, sources),
      group_by(query, sources),
      order_by(query, sources),
      limit(query, sources),
      lock(query.lock),
    ])
  end

  def insert(prefix, source, fields, not_exists) do
    {funcs, fields} = Enum.partition fields, fn
      {_, val} -> match?(%Cassandra.UUID{value: nil}, val)
    end

    {field_names, field_values} = Enum.unzip(fields)
    {func_names, func_values}   = Enum.unzip(funcs)

    names = Enum.map_join(field_names ++ func_names, ", ", &identifier/1)
    marks = marks(Enum.count(field_names))

    func_values = Enum.map_join func_values, ", " , fn
      %Cassandra.UUID{type: :timeuuid, value: nil} -> "now()"
      %Cassandra.UUID{type: :uuid,     value: nil} -> "uuid()"
    end

    values = if func_values == "", do: marks, else: "#{marks}, #{func_values}"
    existence = if not_exists, do: " IF NOT EXISTS", else: ""

    query = "INSERT INTO #{quote_table(prefix, source)} (#{names}) VALUES (#{values})#{existence}"

    {query, field_values}
  end

  defp marks(n) do
    ["?"]
    |> Stream.cycle
    |> Enum.take(n)
    |> Enum.join(", ")
  end

  defp select(%{select: %{fields: fields}} = query, sources) do
    fields
    |> select_fields(sources, query)
    |> prepend("SELECT ")
  end

  defp from(%{from: {name, _schema}, prefix: prefix}, _sources) do
    prefix
    |> quote_table(name)
    |> prepend("FROM ")
  end

  defp where(%{wheres: []}, _), do: []
  defp where(%{wheres: wheres} = query, sources) do
    wheres
    |> boolean(sources, query)
    |> prepend("WHERE ")
  end

  # TODO: GROUP BY added in cassandra 3.10 and has a bad error or previous versions
  # Maybe we must warn user about cassandra version
  defp group_by(%{group_bys: []}, _), do: []
  defp group_by(%{group_bys: group_bys} = query, sources) do
    group_bys
    |> Enum.flat_map(fn %{expr: expr} -> expr end)
    |> Enum.map_join(", ", &expr(&1, sources, query))
    |> prepend("GROUP BY ")
  end

  defp order_by(%{order_bys: []}, _), do: []
  defp order_by(%{order_bys: order_bys} = query, sources) do
    order_bys
    |> Enum.flat_map(fn %{expr: expr} -> expr end)
    |> Enum.map_join(", ", &order_by_expr(&1, sources, query))
    |> prepend("ORDER BY ")
  end

  defp order_by_expr({dir, expr}, sources, query) do
    dir = case dir do
      :asc  -> ""
      :desc -> " DESC"
    end
    expr(expr, sources, query) <> dir
  end

  defp limit(%{limit: nil}, _sources), do: []
  defp limit(%{limit: %{expr: expr}} = query, sources) do
    "LIMIT " <> expr(expr, sources, query)
  end

  defp lock(nil), do: []
  defp lock("ALLOW FILTERING"), do: "ALLOW FILTERING"
  defp lock(_), do: raise ArgumentError, "Cassandra do not support locking"

  defp prepend(str, prefix), do: prefix <> str

  defp boolean([%{expr: expr} | exprs], sources, query) do
    Enum.reduce exprs, paren_expr(expr, sources, query), fn
      %BooleanExpr{expr: e, op: :and}, acc ->
        acc <> " AND " <> paren_expr(e, sources, query)
      %BooleanExpr{expr: e, op: :or}, acc ->
        acc <> " OR " <> paren_expr(e, sources, query)
    end
  end

  defp select_fields([], _sources, _query) do
    raise ArgumentError, "bad select clause"
  end

  defp select_fields(fields, sources, query) do
    Enum.map_join fields, ", ", fn
      {key, value} ->
        expr(value, sources, query) <> " AS " <> identifier(key)
      value ->
        expr(value, sources, query)
    end
  end

  defp identifier(name) when is_atom(name) do
    name |> Atom.to_string |> identifier
  end

  defp identifier(name) do
    if Regex.match?(@identifier, name) do
      name
    else
      raise ArgumentError, "bad identifier #{inspect name}"
    end
  end

  defp quote_name(name) when is_atom(name) do
    name |> Atom.to_string |> quote_name
  end

  defp quote_name(name) do
    if Regex.match?(@unquoted_name, name) do
      <<?", name::binary, ?">>
    else
      raise ArgumentError, "bad field name #{inspect name}"
    end
  end

  defp quote_table(nil, name),    do: quote_table(name)
  defp quote_table(prefix, name), do: quote_table(prefix) <> "." <> quote_table(name)

  defp quote_table(name) when is_atom(name) do
    name |> Atom.to_string |> quote_table
  end

  defp quote_table(name) do
    if Regex.match?(@unquoted_name, name) do
      name
    else
      raise ArgumentError, "bad table name #{inspect name}"
    end
  end

  defp assemble(list) do
    list
    |> List.flatten
    |> Enum.join(" ")
  end

  Enum.map @binary_operators_map, fn {op, term} ->
    defp call_type(unquote(op), 2), do: {:binary_operator, unquote(term)}
  end

  defp call_type(func, _arity), do: {:func, Atom.to_string(func)}

  defp paren_expr(expr, sources, query) do
    "(" <> expr(expr, sources, query) <> ")"
  end

  defp expr({:^, [], [_]}, _sources, _query), do: "?"

  defp expr({{:., _, [{:&, _, [_]}, field]}, _, []}, _sources, _query) when is_atom(field) do
    identifier(field)
  end

  defp expr({:&, _, [_idx, fields, _counter]}, _sources, _query) do
    Enum.map_join(fields, ", ", &identifier/1)
  end

  defp in_arg(terms, sources, query) when is_list(terms) do
    "(" <> Enum.map_join(terms, ",", &expr(&1, sources, query)) <> ")"
  end

  defp in_arg(term, sources, query) do
    expr(term, sources, query)
  end

  defp expr({:fragment, _, [kw]}, _sources, _query) when is_list(kw) or tuple_size(kw) == 3 do
    raise ArgumentError, "Cassandra adapter does not support keyword or interpolated fragments for now!"
  end

  defp expr({:fragment, _, parts}, sources, query) do
    Enum.map_join parts, "", fn
      {:raw, str}   -> str
      {:expr, expr} -> expr(expr, sources, query)
    end
  end

  defp expr({fun, _, args}, sources, query)
  when is_atom(fun) and is_list(args)
  do
    case call_type(fun, length(args)) do
      {:binary_operator, op} ->
        [left, right] = Enum.map(args, &binary_op_arg_expr(&1, sources, query))
        "#{left} #{op} #{right}"

      {:func, func} ->
        params = Enum.map_join(args, ", ", &expr(&1, sources, query))
        "#{func}(#{params})"
    end
  end

  defp expr(nil,   _sources, _query), do: "NULL"
  defp expr(true,  _sources, _query), do: "TRUE"
  defp expr(false, _sources, _query), do: "FALSE"

  defp expr(value, _sources, _query) when is_bitstring(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error      -> "'#{escape_string(value)}'"
    end
  end

  defp expr(value, _sources, _query) when is_integer(value) or is_float(value) do
    "#{value}"
  end

  defp escape_string(value) when is_bitstring(value) do
    String.replace(value, "'", "''")
  end

  defp binary_op_arg_expr({op, _, [_, _]} = expr, sources, query)
  when op in @binary_operators do
    paren_expr(expr, sources, query)
  end

  defp binary_op_arg_expr(expr, sources, query) do
    expr(expr, sources, query)
  end
end