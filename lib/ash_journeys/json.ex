defmodule AshJourneys.Json do
  @moduledoc false
  # Reading and writing the JSON files this package commits: run manifests and the
  # lock. Writing sorts every object's keys so a file's diff shows only what changed.
  # Reading checks each field and collects every problem with its path, so a
  # malformed file is reported whole instead of failing on its first fault.

  @typedoc "A parsed value and the problems found reading it."
  @type result(value) :: {value, [String.t()]}

  @hex64 ~r/\A[0-9a-f]{64}\z/

  @doc "Pretty JSON with sorted keys and a final newline."
  @spec encode!(term()) :: String.t()
  def encode!(data), do: data |> ordered() |> Jason.encode!(pretty: true) |> Kernel.<>("\n")

  defp ordered(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.map(fn {key, value} -> {key, ordered(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(value), do: value

  @doc "Decodes `bytes`, or says why it is not a JSON object."
  @spec decode_object(binary(), String.t()) :: {:ok, map()} | {:error, [String.t()]}
  def decode_object(bytes, what) do
    case Jason.decode(bytes) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, ["#{what}: expected a JSON object"]}
      {:error, error} -> {:error, ["#{what}: not JSON (#{Exception.message(error)})"]}
    end
  end

  @doc "Problems for keys of `map` that are not in `known`."
  @spec unknown_keys(map(), [String.t()], String.t()) :: [String.t()]
  def unknown_keys(map, known, path) do
    for key <- map |> Map.keys() |> Enum.sort(),
        key not in known,
        do: "#{path}.#{key}: unknown key"
  end

  @doc """
  Reads `map[key]` with `read`, a function of the value and its path returning
  `{value, problems}`. A missing key is a problem.
  """
  @spec field(map(), String.t(), String.t(), (term(), String.t() -> result(term()))) ::
          result(term())
  def field(map, key, path, read) do
    case Map.fetch(map, key) do
      {:ok, value} -> read.(value, "#{path}.#{key}")
      :error -> {nil, ["#{path}.#{key}: missing"]}
    end
  end

  @doc "A reader that accepts a value when `test` holds, described as `expected`."
  @spec check((term() -> boolean()), String.t()) :: (term(), String.t() -> result(term()))
  def check(test, expected) do
    fn value, path ->
      if test.(value),
        do: {value, []},
        else: {nil, ["#{path}: expected #{expected}, got #{inspect(value)}"]}
    end
  end

  @doc "`read`, or `nil` when the value is `null`."
  @spec nullable((term(), String.t() -> result(term()))) :: (term(), String.t() -> result(term()))
  def nullable(read),
    do: fn value, path -> if is_nil(value), do: {nil, []}, else: read.(value, path) end

  @doc "A reader for one of `values`, given as atoms and written as their strings."
  @spec enum([atom()]) :: (term(), String.t() -> result(atom()))
  def enum(values) do
    names = Map.new(values, &{Atom.to_string(&1), &1})

    fn value, path ->
      case names do
        %{^value => atom} ->
          {atom, []}

        _ ->
          {nil,
           ["#{path}: expected one of #{Enum.join(Map.keys(names), ", ")}, got #{inspect(value)}"]}
      end
    end
  end

  @doc "A reader for a list whose items `read` reads."
  @spec list((term(), String.t() -> result(term()))) :: (term(), String.t() -> result(list()))
  def list(read) do
    fn
      value, path when is_list(value) ->
        {items, problems} =
          value
          |> Enum.with_index()
          |> Enum.map(fn {item, index} -> read.(item, "#{path}[#{index}]") end)
          |> Enum.unzip()

        {items, Enum.concat(problems)}

      value, path ->
        {nil, ["#{path}: expected a list, got #{inspect(value)}"]}
    end
  end

  @doc "A reader for a JSON object, handed to `read` once it is known to be one."
  @spec object((map(), String.t() -> result(term()))) :: (term(), String.t() -> result(term()))
  def object(read) do
    fn
      value, path when is_map(value) -> read.(value, path)
      value, path -> {nil, ["#{path}: expected an object, got #{inspect(value)}"]}
    end
  end

  @doc "A non-empty string."
  def string, do: check(&(is_binary(&1) and &1 != ""), "a non-empty string")

  @doc "A SHA-256 as 64 lowercase hex characters."
  def digest,
    do: check(&(is_binary(&1) and &1 =~ @hex64), "a sha256 (64 lowercase hex characters)")

  @doc "An integer of at least `min`."
  def integer(min), do: check(&(is_integer(&1) and &1 >= min), "an integer >= #{min}")

  @doc "A boolean."
  def boolean, do: check(&is_boolean/1, "a boolean")

  @doc "Whether `value` is a SHA-256 as lowercase hex."
  @spec sha256?(term()) :: boolean()
  def sha256?(value), do: is_binary(value) and value =~ @hex64

  @doc "The SHA-256 of `bytes`, as lowercase hex."
  @spec sha256(iodata()) :: String.t()
  def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
