defmodule Optimus.Builder do
  alias Optimus
  alias Optimus.PropertyParsers, as: PP

  def build(props) do
    build_(props)
  end

  def build_(props, global_props \\ %{}) do
    with :ok <- validate_keyword_list(props),
         {:ok, name} <- build_name(props),
         {:ok, description} <- build_description(props),
         {:ok, version} <- build_version(props),
         {:ok, author} <- build_author(props),
         {:ok, about} <- build_about(props),
         {:ok, summary} <- build_summary(props, about),
         {:ok, allow_unknown_args} <- build_allow_unknown_args(props),
         {:ok, parse_double_dash} <- build_parse_double_dash(props),
         {:ok, args} <- build_args(props[:args]),
         {:ok, flags} <- build_flags(props[:flags]),
         {:ok, options} <- build_options(props[:options]),
         {:ok, global_props} <- build_global_props(flags, options, global_props),
         {:ok, subcommands} <- build_subcommands(props[:subcommands], global_props),
         :ok <- validate_args(args),
         :ok <- validate_conflicts(flags, options),
         do:
           {:ok,
            %Optimus{
              name: name,
              description: description,
              version: version,
              author: author,
              about: about,
              summary: summary,
              allow_unknown_args: allow_unknown_args,
              parse_double_dash: parse_double_dash,
              args: args,
              flags: flags,
              options: options,
              subcommands: subcommands
            }}
  end

  defp build_name(props) do
    PP.build_command_name(:name, props[:name])
  end

  defp build_description(props) do
    PP.build_string(:description, props[:description], nil)
  end

  defp build_version(props) do
    PP.build_string(:version, props[:version], nil)
  end

  defp build_author(props) do
    PP.build_string(:author, props[:author], nil)
  end

  defp build_about(props) do
    PP.build_string(:about, props[:about], nil)
  end

  defp build_summary(props, about) do
    with {:ok, summary} <- PP.build_string(:summary, props[:summary], nil) do
      value =
        case {summary, about} do
          {nil, nil} -> nil
          {nil, about} -> String.split(about, "\n\n") |> List.first() |> String.trim()
          {summary, _} -> summary
        end

      {:ok, value}
    end
  end

  defp build_allow_unknown_args(props) do
    PP.build_bool(:allow_unknown_args, props[:allow_unknown_args], false)
  end

  defp build_parse_double_dash(props) do
    PP.build_bool(:parse_double_dash, props[:parse_double_dash], true)
  end

  defp build_args(specs), do: build_specs("args", Optimus.Arg, specs)
  defp build_flags(specs), do: build_specs("flags", Optimus.Flag, specs)
  defp build_options(specs), do: build_specs("options", Optimus.Option, specs)

  defp build_specs(_name, _module, nil), do: {:ok, []}

  defp build_specs(name, module, specs) do
    if Keyword.keyword?(specs) do
      build_specs_(module, specs, [])
    else
      {:error, "#{name} specs are expected to be a Keyword list"}
    end
  end

  defp build_specs_(_module, [], parsed), do: {:ok, Enum.reverse(parsed)}

  defp build_specs_(module, [{_name, _props} = arg_spec | other], parsed) do
    with {:ok, arg} <- module.new(arg_spec), do: build_specs_(module, other, [arg | parsed])
  end

  defp build_subcommands(nil, _gloal_props), do: {:ok, []}

  defp build_subcommands(subcommands, gloal_props) do
    if Keyword.keyword?(subcommands) do
      build_subcommands_(subcommands, gloal_props, [])
    else
      {:error, "subcommand specs are expected to be a Keyword list"}
    end
  end

  defp build_subcommands_([], _gloal_props, parsed), do: {:ok, Enum.reverse(parsed)}

  defp build_subcommands_([{subcommand_name, props} | other], global_props, parsed) do
    case build_(props, global_props) do
      {:ok, subcommand} ->
        subcommand = merge_globals_into_subcommand(subcommand, global_props)

        subcommand_with_name =
          case subcommand.name do
            nil ->
              %Optimus{subcommand | subcommand: subcommand_name, name: to_string(subcommand_name)}

            _ ->
              %Optimus{subcommand | subcommand: subcommand_name}
          end

        build_subcommands_(other, global_props, [subcommand_with_name | parsed])

      {:error, error} ->
        {:error, "error building subcommand #{inspect(subcommand_name)}: #{error}"}
    end
  end

  def validate_keyword_list(list) do
    if Keyword.keyword?(list) do
      :ok
    else
      {:error, "configuration is expected to be a keyword list"}
    end
  end

  defp validate_args([arg1, arg2 | other]) do
    if !arg1.required && arg2.required do
      {:error,
       "required argument #{inspect(arg2.name)} follows optional argument #{inspect(arg1.name)}"}
    else
      validate_args([arg2 | other])
    end
  end

  defp validate_args(_), do: :ok

  defp validate_conflicts(flags, options) do
    with :ok <- validate_conflicts(flags, options, :short),
         :ok <- validate_conflicts(flags, options, :long),
         do: :ok
  end

  defp validate_conflicts(flags, options, key) do
    all_options = flags ++ options

    duplicate =
      all_options
      |> Enum.group_by(fn item -> Map.get(item, key) end, fn item -> item end)
      |> Map.to_list()
      |> Enum.find(fn {option_name, options} -> option_name && length(options) > 1 end)

    case duplicate do
      {name, _} -> {:error, "duplicate #{key} option name: #{name}"}
      nil -> :ok
    end
  end

  defp build_global_props(local_flags, local_options, global_props) do
    global_flags = build_global_props_by_type(local_flags, :flags, global_props)
    global_options = build_global_props_by_type(local_options, :options, global_props)

    {:ok, %{flags: global_flags, options: global_options}}
  end

  defp build_global_props_by_type(local_props, type, global_props) do
    local_props
    # Keep only global flags
    |> Enum.filter(& &1.global)
    # Hide global props on subcommands
    |> Enum.map(&%{&1 | hide: true})
    # Add previous defined global flags
    |> Kernel.++(Map.get(global_props, type, []))
  end

  defp merge_globals_into_subcommand(
         subcommand,
         %{flags: global_flags, options: global_options} = _gloal_props
       ) do
    subcommand
    |> Map.update(:flags, [], fn flags -> flags ++ global_flags end)
    |> Map.update(:options, [], fn options -> options ++ global_options end)
  end
end
