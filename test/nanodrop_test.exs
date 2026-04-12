defmodule NanodropTest do
  use ExUnit.Case
  doctest Nanodrop

  alias Nanodrop.OOI

  describe "OOI.from_raw/1" do
    test "decodes 16-bit little-endian pixel values" do
      # Create fake spectrum data: 2048 pixels, each 16-bit LE
      data = :binary.copy(<<100::little-16>>, 2048)

      ooi = OOI.from_raw(data)

      assert length(ooi.raw_pixels) == 2048
      assert Enum.all?(ooi.raw_pixels, &(&1 == 100))
    end

    test "handles varying pixel values" do
      # First 4 pixels: 0, 256, 512, 1024
      data =
        <<0::little-16, 256::little-16, 512::little-16, 1024::little-16>> <>
          :binary.copy(<<0::little-16>>, 2044)

      ooi = OOI.from_raw(data)

      assert Enum.take(ooi.raw_pixels, 4) == [0, 256, 512, 1024]
    end

    test "sets timestamp" do
      data = :binary.copy(<<0::little-16>>, 2048)

      ooi = OOI.from_raw(data)

      assert %DateTime{} = ooi.timestamp
    end
  end

  describe "OOI.dark_pixels/1" do
    test "returns pixels 2-24" do
      # Create spectrum with sequential values for easy verification
      data =
        for i <- 0..2047, into: <<>> do
          <<i::little-16>>
        end

      ooi = OOI.from_raw(data)
      dark = OOI.dark_pixels(ooi)

      assert length(dark) == 23
      assert hd(dark) == 2
      assert List.last(dark) == 24
    end
  end

  describe "OOI.dark_average/1" do
    test "calculates average of dark pixels" do
      # Create spectrum where dark pixels (2-24) are all 100
      pixels =
        for i <- 0..2047 do
          if i >= 2 and i <= 24, do: 100, else: 0
        end

      data = for p <- pixels, into: <<>>, do: <<p::little-16>>
      ooi = OOI.from_raw(data)

      assert OOI.dark_average(ooi) == 100.0
    end
  end

  describe "OOI.max_intensity/1" do
    test "returns maximum pixel value" do
      data =
        <<0::little-16, 1000::little-16, 500::little-16>> <>
          :binary.copy(<<0::little-16>>, 2045)

      ooi = OOI.from_raw(data)

      assert OOI.max_intensity(ooi) == 1000
    end
  end
end
