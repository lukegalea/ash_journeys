defmodule AshJourneys.Raster do
  @moduledoc """
  A figure's pixels, independent of how its PNG was encoded.

  Two browser builds can write different PNG bytes for identical pixels, so a lock
  over file bytes churns on every browser update. Figures are compared by their
  raster instead: the decoded pixels as 8-bit RGBA.

  `hash/1` is the **raster hash**: the SHA-256, as lowercase hex, of

      <<width::32-big, height::32-big>> <> rgba

  where `rgba` is the pixels row by row from the top left, four bytes each. An RGB
  image gets an alpha of 255, so the same pixels hash the same whichever colour type
  wrote them. A runner records it for each figure as `raster_sha256`; this package
  recomputes it from the figure's bytes before approving.

  Decoding needs no dependency (`:zlib` is part of OTP) and reads what browsers
  write for screenshots: 8-bit RGB or RGBA, not interlaced. Anything else is
  refused, never guessed at.

  `diff/2` compares two rasters pixel by pixel and `within?/2` holds when the
  difference is inside a tolerance (see `AshJourneys.Lock`). The tolerance only
  decides whether a figure *changed* for review. It never touches a recorded hash.
  """

  import Bitwise

  defstruct [:width, :height, :rgba]

  @type t :: %__MODULE__{width: pos_integer(), height: pos_integer(), rgba: binary()}

  @typedoc """
  How two rasters differ: `size` when their dimensions differ (then nothing else is
  compared), else the number of pixels that differ, the largest difference of any
  one channel, and the box holding every differing pixel (`nil` when none differ).
  """
  @type diff ::
          %{size: {{pos_integer(), pos_integer()}, {pos_integer(), pos_integer()}}}
          | %{
              pixels: non_neg_integer(),
              max_delta: 0..255,
              bbox:
                %{
                  x: non_neg_integer(),
                  y: non_neg_integer(),
                  width: pos_integer(),
                  height: pos_integer()
                }
                | nil
            }

  @typedoc "A tolerance: at most `pixels` pixels differ, none by more than `channel_delta`."
  @type tolerance :: %{pixels: non_neg_integer(), channel_delta: 0..255}

  @signature <<137, 80, 78, 71, 13, 10, 26, 10>>
  @max_pixels 64_000_000
  @gap 8
  @padding <<128, 128, 128, 255>>
  @marker <<255, 0, 255, 255>>

  @doc "The raster hash of a raster (see the moduledoc)."
  @spec hash(t()) :: String.t()
  def hash(%__MODULE__{width: width, height: height, rgba: rgba}),
    do: AshJourneys.Json.sha256([<<width::32, height::32>>, rgba])

  @doc """
  Decodes PNG bytes into a raster. Refuses a bad signature or checksum, a colour
  type or bit depth other than 8-bit RGB or RGBA, interlacing, and image data that
  inflates to a size other than the header promises.
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, String.t()}
  def decode(<<@signature, rest::binary>>) do
    with {:ok, chunks} <- chunks(rest, []),
         {:ok, header} <- header(chunks),
         {:ok, data} <- inflate(header, for({"IDAT", data} <- chunks, do: data)),
         {:ok, pixels} <- unfilter(header, data) do
      {:ok, %__MODULE__{width: header.width, height: header.height, rgba: rgba(header, pixels)}}
    end
  end

  def decode(_bytes), do: {:error, "not a PNG"}

  defp chunks(
         <<length::32, type::binary-4, data::binary-size(length), crc::32, rest::binary>>,
         acc
       ) do
    cond do
      :erlang.crc32([type, data]) != crc -> {:error, "the #{type} chunk fails its checksum"}
      type == "IEND" -> {:ok, Enum.reverse(acc)}
      true -> chunks(rest, [{type, data} | acc])
    end
  end

  defp chunks(_rest, _acc), do: {:error, "the PNG is truncated"}

  defp header([{"IHDR", <<width::32, height::32, 8, color, 0, 0, 0>>} | _])
       when color in [2, 6] and width > 0 and height > 0 and width * height <= @max_pixels do
    channels = if color == 6, do: 4, else: 3
    {:ok, %{width: width, height: height, channels: channels, stride: width * channels}}
  end

  defp header([{"IHDR", <<_w::32, _h::32, depth, color, _c, _f, interlace>>} | _]) do
    {:error,
     "unsupported PNG (bit depth #{depth}, colour type #{color}, interlace #{interlace}); " <>
       "expected 8-bit RGB or RGBA, not interlaced, at most #{@max_pixels} pixels"}
  end

  defp header(_chunks), do: {:error, "the PNG has no IHDR chunk first"}

  # Inflates at most the size the header promises, so a crafted image cannot make
  # the decoder allocate more than its own dimensions.
  defp inflate(_header, []), do: {:error, "the PNG has no image data"}

  defp inflate(%{height: height, stride: stride}, idat) do
    expected = height * (stride + 1)
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z)
      inflated(z, :zlib.safeInflate(z, idat), expected, [], 0)
    rescue
      ErlangError -> {:error, "the PNG's image data does not inflate"}
    after
      :zlib.close(z)
    end
  end

  defp inflated(z, {state, out}, expected, acc, size) do
    size = size + :erlang.iolist_size(out)

    cond do
      size > expected -> {:error, "the PNG's image data is larger than its header says"}
      state == :continue -> inflated(z, :zlib.safeInflate(z, []), expected, [acc, out], size)
      size < expected -> {:error, "the PNG's image data is smaller than its header says"}
      true -> {:ok, IO.iodata_to_binary([acc, out])}
    end
  end

  defp unfilter(%{channels: channels, stride: stride}, data) do
    data
    |> rows(stride + 1)
    |> Enum.reduce_while({[], :binary.copy(<<0>>, stride)}, fn
      <<filter, line::binary>>, {acc, previous} when filter in 0..4 ->
        row = unfilter_row(filter, line, previous, channels)
        {:cont, {[acc, row], row}}

      <<filter, _line::binary>>, _acc ->
        {:halt, {:error, "the PNG uses an unknown row filter #{filter}"}}
    end)
    |> case do
      {:error, _reason} = error -> error
      {rows, _previous} -> {:ok, IO.iodata_to_binary(rows)}
    end
  end

  defp rows(data, size), do: for(<<row::binary-size(^size) <- data>>, do: row)

  defp unfilter_row(0, line, _previous, _bpp), do: line

  defp unfilter_row(2, line, previous, _bpp) do
    :binary.list_to_bin(
      :lists.zipwith(
        fn x, b -> x + b &&& 255 end,
        :binary.bin_to_list(line),
        :binary.bin_to_list(previous)
      )
    )
  end

  defp unfilter_row(filter, line, previous, bpp) when filter in [1, 3, 4] do
    zero = List.duplicate(0, bpp)

    line
    |> :binary.bin_to_list()
    |> walk(:binary.bin_to_list(previous), zero, zero, filter, bpp, [])
    |> :binary.list_to_bin()
  end

  # One pixel at a time: `left` and `up_left` are the reconstructed pixel to the
  # left and the one above it, as lists of `bpp` bytes.
  defp walk([], _up, _left, _up_left, _filter, _bpp, acc),
    do: acc |> Enum.reverse() |> Enum.concat()

  defp walk(line, up, left, up_left, filter, bpp, acc) do
    {x, line} = Enum.split(line, bpp)
    {b, up} = Enum.split(up, bpp)

    pixel =
      :lists.zipwith3(
        fn x, {a, b}, c -> x + predict(filter, a, b, c) &&& 255 end,
        x,
        Enum.zip(left, b),
        up_left
      )

    walk(line, up, pixel, b, filter, bpp, [pixel | acc])
  end

  defp predict(1, a, _b, _c), do: a
  defp predict(3, a, b, _c), do: (a + b) >>> 1

  defp predict(4, a, b, c) do
    p = a + b - c
    {pa, pb, pc} = {abs(p - a), abs(p - b), abs(p - c)}

    cond do
      pa <= pb and pa <= pc -> a
      pb <= pc -> b
      true -> c
    end
  end

  defp rgba(%{channels: 4}, pixels), do: pixels

  defp rgba(%{channels: 3}, pixels),
    do: for(<<r, g, b <- pixels>>, into: <<>>, do: <<r, g, b, 255>>)

  @doc "PNG bytes for a raster: 8-bit RGBA, no filtering."
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{width: width, height: height, rgba: rgba}) do
    data = for row <- rows(rgba, width * 4), into: <<>>, do: <<0, row::binary>>

    IO.iodata_to_binary([
      @signature,
      chunk("IHDR", <<width::32, height::32, 8, 6, 0, 0, 0>>),
      chunk("IDAT", :zlib.compress(data)),
      chunk("IEND", <<>>)
    ])
  end

  defp chunk(type, data),
    do: [<<byte_size(data)::32>>, type, data, <<:erlang.crc32([type, data])::32>>]

  @doc "How raster `b` differs from raster `a` (see `t:diff/0`)."
  @spec diff(t(), t()) :: diff()
  def diff(%__MODULE__{width: w, height: h} = a, %__MODULE__{width: w, height: h} = b) do
    rows(a.rgba, w * 4)
    |> Enum.zip(rows(b.rgba, w * 4))
    |> Enum.with_index()
    |> Enum.reduce(%{pixels: 0, max_delta: 0, bbox: nil}, fn
      {{same, same}, _y}, acc -> acc
      {{row_a, row_b}, y}, acc -> row_diff(row_a, row_b, y, 0, acc)
    end)
    |> Map.update!(:bbox, &bbox/1)
  end

  def diff(%__MODULE__{} = a, %__MODULE__{} = b),
    do: %{size: {{a.width, a.height}, {b.width, b.height}}}

  defp row_diff(<<p::binary-4, row_a::binary>>, <<p::binary-4, row_b::binary>>, y, x, acc),
    do: row_diff(row_a, row_b, y, x + 1, acc)

  defp row_diff(<<r1, g1, b1, a1, row_a::binary>>, <<r2, g2, b2, a2, row_b::binary>>, y, x, acc) do
    delta = Enum.max([abs(r1 - r2), abs(g1 - g2), abs(b1 - b2), abs(a1 - a2)])
    box = acc.bbox || {x, y, x, y}
    {x0, y0, x1, y1} = box

    acc = %{
      pixels: acc.pixels + 1,
      max_delta: max(acc.max_delta, delta),
      bbox: {min(x0, x), min(y0, y), max(x1, x), max(y1, y)}
    }

    row_diff(row_a, row_b, y, x + 1, acc)
  end

  defp row_diff(<<>>, <<>>, _y, _x, acc), do: acc

  defp bbox(nil), do: nil
  defp bbox({x0, y0, x1, y1}), do: %{x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1}

  @doc """
  Whether a difference is inside a tolerance: the same dimensions, at most
  `tolerance.pixels` differing pixels and no channel off by more than
  `tolerance.channel_delta`.
  """
  @spec within?(diff(), tolerance()) :: boolean()
  def within?(%{size: _}, _tolerance), do: false

  def within?(%{pixels: pixels, max_delta: delta}, %{pixels: max_pixels, channel_delta: max_delta}),
      do: pixels <= max_pixels and delta <= max_delta

  @doc """
  A raster showing `before` and `after` side by side, then, when their dimensions
  match, `after` dimmed with every differing pixel in magenta. Panels are separated
  and padded in grey.
  """
  @spec side_by_side(t(), t()) :: t()
  def side_by_side(%__MODULE__{} = before, %__MODULE__{} = after_) do
    panels =
      if {before.width, before.height} == {after_.width, after_.height},
        do: [before, after_, marked(before, after_)],
        else: [before, after_]

    height = panels |> Enum.map(& &1.height) |> Enum.max()
    gap = :binary.copy(@padding, @gap)

    rgba =
      for y <- 0..(height - 1), into: <<>> do
        panels |> Enum.map(&panel_row(&1, y)) |> Enum.intersperse(gap) |> IO.iodata_to_binary()
      end

    width = Enum.sum(Enum.map(panels, & &1.width)) + @gap * (length(panels) - 1)
    %__MODULE__{width: width, height: height, rgba: rgba}
  end

  defp panel_row(%__MODULE__{width: w, height: h, rgba: rgba}, y) when y < h,
    do: binary_part(rgba, y * w * 4, w * 4)

  defp panel_row(%__MODULE__{width: w}, _y), do: :binary.copy(@padding, w)

  defp marked(%__MODULE__{width: w} = a, %__MODULE__{} = b) do
    rgba =
      rows(a.rgba, w * 4)
      |> Enum.zip(rows(b.rgba, w * 4))
      |> Enum.map(fn {row_a, row_b} -> mark_row(row_a, row_b, []) end)
      |> IO.iodata_to_binary()

    %__MODULE__{b | rgba: rgba}
  end

  defp mark_row(<<p::binary-4, row_a::binary>>, <<p::binary-4, row_b::binary>>, acc) do
    <<r, g, b, _a>> = p
    mark_row(row_a, row_b, [acc, <<div(r, 3), div(g, 3), div(b, 3), 255>>])
  end

  defp mark_row(<<_::binary-4, row_a::binary>>, <<_::binary-4, row_b::binary>>, acc),
    do: mark_row(row_a, row_b, [acc, @marker])

  defp mark_row(<<>>, <<>>, acc), do: acc
end
