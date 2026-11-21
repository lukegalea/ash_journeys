defmodule AshJourneys.RasterTest do
  use ExUnit.Case, async: true

  alias AshJourneys.Raster
  alias AshJourneys.Test.Runs

  @fixtures Path.expand("../fixtures/raster", __DIR__)

  # Raster hashes computed independently with Pillow 12.3:
  #   sha256(struct.pack(">II", w, h) + Image.open(f).convert("RGBA").tobytes())
  # The files are Pillow's own optimised encodings, which use row filters 1-4.
  @pillow %{
    "rgba.png" => {61, 37, "802cd8cdf035666529d9539b6c31f3ee8257cddc23f89e4209ed68069a6ef9b1"},
    "rgb.png" => {61, 37, "81d55561fe47c66d97e5d9318a64bfaa1efa695a72f8e7e401c47cb053b7f7ac"},
    "stripes.png" => {53, 29, "2c790a0c9d9b233301112d6ba5f373a17ad540be3ab7e028f9ba3e3b9130cadd"}
  }

  describe "decode/1 and hash/1" do
    for {file, {width, height, hash}} <- @pillow do
      test "#{file} decodes to the raster Pillow decodes" do
        {:ok, raster} = Raster.decode(File.read!(Path.join(@fixtures, unquote(file))))
        assert {raster.width, raster.height} == {unquote(width), unquote(height)}
        assert byte_size(raster.rgba) == unquote(width * height * 4)
        assert Raster.hash(raster) == unquote(hash)
      end
    end

    test "an RGB image gets an opaque alpha" do
      {:ok, raster} = Raster.decode(File.read!(Path.join(@fixtures, "rgb.png")))
      assert for(<<_r, _g, _b, a <- raster.rgba>>, uniq: true, do: a) == [255]
    end

    test "the hash covers the dimensions, not only the pixels" do
      wide = Runs.raster(4, 1)
      tall = Runs.raster(1, 4)
      assert wide.rgba == tall.rgba
      refute Raster.hash(wide) == Raster.hash(tall)
    end

    test "encode/1 round-trips, and its bytes differ from another encoder's for the same pixels" do
      {:ok, raster} = Raster.decode(File.read!(Path.join(@fixtures, "rgba.png")))
      png = Raster.encode(raster)
      assert {:ok, ^raster} = Raster.decode(png)
      refute png == File.read!(Path.join(@fixtures, "rgba.png"))
    end
  end

  describe "decode/1 refuses" do
    setup do
      %{png: Raster.encode(Runs.raster(3, 2))}
    end

    test "bytes that are not a PNG" do
      assert {:error, "not a PNG"} = Raster.decode("GIF89a")
      assert {:error, "not a PNG"} = Raster.decode(<<>>)
    end

    test "a chunk whose checksum fails", %{png: png} do
      <<head::binary-size(30), byte, rest::binary>> = png

      assert {:error, "the IHDR chunk fails its checksum"} =
               Raster.decode(<<head::binary, Bitwise.bxor(byte, 1), rest::binary>>)
    end

    test "a truncated file", %{png: png} do
      assert {:error, "the PNG is truncated"} =
               Raster.decode(binary_part(png, 0, byte_size(png) - 6))
    end

    test "colour types and depths a browser screenshot does not use" do
      for {depth, colour, interlace} <- [{16, 6, 0}, {8, 3, 0}, {8, 0, 0}, {8, 6, 1}] do
        png =
          png([
            {"IHDR", <<2::32, 2::32, depth, colour, 0, 0, interlace>>},
            {"IDAT", :zlib.compress(<<0>>)}
          ])

        assert {:error, "unsupported PNG" <> _} = Raster.decode(png)
      end
    end

    test "image data that inflates to more than the header promises" do
      bomb = :zlib.compress(:binary.copy(<<0>>, 10_000_000))
      png = png([{"IHDR", <<2::32, 2::32, 8, 6, 0, 0, 0>>}, {"IDAT", bomb}])
      assert {:error, "the PNG's image data is larger than its header says"} = Raster.decode(png)
    end

    test "image data that inflates to less than the header promises" do
      png =
        png([{"IHDR", <<2::32, 2::32, 8, 6, 0, 0, 0>>}, {"IDAT", :zlib.compress(<<0, 1, 2>>)}])

      assert {:error, "the PNG's image data is smaller than its header says"} = Raster.decode(png)
    end

    test "image data that is not zlib" do
      png = png([{"IHDR", <<2::32, 2::32, 8, 6, 0, 0, 0>>}, {"IDAT", "not zlib at all"}])
      assert {:error, "the PNG's image data does not inflate"} = Raster.decode(png)
    end

    test "no image data, or no header first" do
      assert {:error, "the PNG has no image data"} =
               Raster.decode(png([{"IHDR", <<2::32, 2::32, 8, 6, 0, 0, 0>>}]))

      assert {:error, "the PNG has no IHDR chunk first"} =
               Raster.decode(png([{"IDAT", :zlib.compress(<<0>>)}]))
    end

    test "an unknown row filter" do
      rows = <<5, 0, 0, 0, 0>>
      png = png([{"IHDR", <<1::32, 1::32, 8, 6, 0, 0, 0>>}, {"IDAT", :zlib.compress(rows)}])
      assert {:error, "the PNG uses an unknown row filter 5"} = Raster.decode(png)
    end
  end

  describe "diff/2 and within?/2" do
    @tolerance %{pixels: 32, channel_delta: 64}

    test "identical rasters differ in nothing" do
      raster = Runs.raster()
      assert Raster.diff(raster, raster) == %{pixels: 0, max_delta: 0, bbox: nil}
      assert Raster.within?(Raster.diff(raster, raster), @tolerance)
    end

    test "counts differing pixels, the largest channel delta and their box" do
      base = Runs.raster()
      wobble = Runs.raster(40, 30, [{3, 5, <<20, 40, 95, 255>>}, {10, 7, <<30, 40, 60, 255>>}])

      assert Raster.diff(base, wobble) == %{
               pixels: 2,
               max_delta: 35,
               bbox: %{x: 3, y: 5, width: 8, height: 3}
             }
    end

    test "a wobble of up to 32 pixels and a delta of up to 64 is within the tolerance" do
      base = Runs.raster()
      at_bound = Runs.raster(40, 30, for(x <- 0..31, do: {x, 0, <<84, 40, 60, 255>>}))
      assert %{pixels: 32, max_delta: 64} = diff = Raster.diff(base, at_bound)
      assert Raster.within?(diff, @tolerance)
    end

    test "a 33rd pixel, or a delta of 65, is a change" do
      base = Runs.raster()
      too_many = Runs.raster(40, 30, for(x <- 0..32, do: {x, 0, <<21, 40, 60, 255>>}))
      too_far = Runs.raster(40, 30, [{0, 0, <<85, 40, 60, 255>>}])
      alpha = Runs.raster(40, 30, [{0, 0, <<20, 40, 60, 0>>}])

      refute Raster.within?(Raster.diff(base, too_many), @tolerance)
      refute Raster.within?(Raster.diff(base, too_far), @tolerance)
      refute Raster.within?(Raster.diff(base, alpha), @tolerance)
    end

    test "rasters of different sizes are compared no further and never within a tolerance" do
      diff = Raster.diff(Runs.raster(40, 30), Runs.raster(40, 31))
      assert diff == %{size: {{40, 30}, {40, 31}}}
      refute Raster.within?(diff, %{pixels: 1_000_000, channel_delta: 255})
    end
  end

  describe "side_by_side/2" do
    test "puts before, after and the marked difference in one raster" do
      before = Runs.raster(4, 2)
      after_ = Runs.raster(4, 2, [{1, 1, <<200, 200, 200, 255>>}])
      image = Raster.side_by_side(before, after_)

      assert {image.width, image.height} == {4 * 3 + 8 * 2, 2}
      # Row 1, third panel (x offset 24): the changed pixel is magenta, the rest dimmed.
      row = binary_part(image.rgba, 1 * image.width * 4 + 24 * 4, 16)
      assert row == <<6, 13, 20, 255, 255, 0, 255, 255, 6, 13, 20, 255, 6, 13, 20, 255>>
      assert {:ok, ^image} = Raster.decode(Raster.encode(image))
    end

    test "pads the shorter panel and leaves out the difference when sizes differ" do
      image = Raster.side_by_side(Runs.raster(4, 2), Runs.raster(5, 3))
      assert {image.width, image.height} == {4 + 8 + 5, 3}
      assert binary_part(image.rgba, 2 * image.width * 4, 4) == <<128, 128, 128, 255>>
    end
  end

  defp png(chunks) do
    IO.iodata_to_binary([
      <<137, 80, 78, 71, 13, 10, 26, 10>>,
      for(
        {type, data} <- chunks ++ [{"IEND", <<>>}],
        do: [<<byte_size(data)::32>>, type, data, <<:erlang.crc32([type, data])::32>>]
      )
    ])
  end
end
