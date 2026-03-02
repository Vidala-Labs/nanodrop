defmodule NanodropTest do
  use ExUnit.Case
  doctest Nanodrop

  alias Nanodrop.Spectrum

  describe "Spectrum.from_raw/1" do
    test "decodes 16-bit little-endian pixel values" do
      # Create fake spectrum data: 2048 pixels, each 16-bit LE
      data = :binary.copy(<<100::little-16>>, 2048)

      spectrum = Spectrum.from_raw(data)

      assert length(spectrum.raw_pixels) == 2048
      assert Enum.all?(spectrum.raw_pixels, &(&1 == 100))
    end

    test "handles varying pixel values" do
      # First 4 pixels: 0, 256, 512, 1024
      data =
        <<0::little-16, 256::little-16, 512::little-16, 1024::little-16>> <>
          :binary.copy(<<0::little-16>>, 2044)

      spectrum = Spectrum.from_raw(data)

      assert Enum.take(spectrum.raw_pixels, 4) == [0, 256, 512, 1024]
    end
  end

  describe "Spectrum.dark_pixels/1" do
    test "returns pixels 2-24" do
      # Create spectrum with sequential values for easy verification
      data =
        for i <- 0..2047, into: <<>> do
          <<i::little-16>>
        end

      spectrum = Spectrum.from_raw(data)
      dark = Spectrum.dark_pixels(spectrum)

      assert length(dark) == 23
      assert hd(dark) == 2
      assert List.last(dark) == 24
    end
  end

  describe "Spectrum.wavelength_at/2" do
    test "calculates wavelength using polynomial" do
      calibration = %{
        intercept: 200.0,
        first_coefficient: 0.5,
        second_coefficient: 0.0001,
        third_coefficient: 0.0
      }

      data = :binary.copy(<<0::little-16>>, 2048)
      spectrum = data |> Spectrum.from_raw() |> Spectrum.with_calibration(calibration)

      # λ(0) = 200 + 0.5*0 + 0.0001*0 = 200
      assert Spectrum.wavelength_at(spectrum, 0) == 200.0

      # λ(100) = 200 + 0.5*100 + 0.0001*10000 = 200 + 50 + 1 = 251
      assert Spectrum.wavelength_at(spectrum, 100) == 251.0
    end

    test "returns error without calibration" do
      data = :binary.copy(<<0::little-16>>, 2048)
      spectrum = Spectrum.from_raw(data)

      assert Spectrum.wavelength_at(spectrum, 0) == {:error, :no_calibration}
    end
  end

  describe "Spectrum.dark_subtract/1" do
    test "subtracts average dark value from all pixels" do
      # Create spectrum where dark pixels (2-24) average to 10
      pixels =
        for i <- 0..2047 do
          if i >= 2 and i <= 24, do: 10, else: 100
        end

      data = for p <- pixels, into: <<>>, do: <<p::little-16>>
      spectrum = Spectrum.from_raw(data)

      corrected = Spectrum.dark_subtract(spectrum)

      # Non-dark pixels should be 100 - 10 = 90
      assert Enum.at(corrected.raw_pixels, 100) == 90
    end
  end
end
