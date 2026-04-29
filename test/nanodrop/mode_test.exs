defmodule Nanodrop.ModeTest do
  use ExUnit.Case

  alias Nanodrop.Mode
  alias Nanodrop.Mode.DNA
  alias Nanodrop.Spectrum

  # Sample spectrum data for testing
  defp sample_spectrum do
    # Create a simple spectrum with a peak around 260nm
    wavelengths = Enum.map(220..400, &(&1 * 1.0))

    absorbance =
      Enum.map(wavelengths, fn wl ->
        # Gaussian-ish peak centered at 260nm
        peak = :math.exp(-:math.pow(wl - 260, 2) / 500)
        # Add some baseline slope
        baseline = 0.1 + (400 - wl) * 0.0005
        peak * 0.5 + baseline
      end)

    Spectrum.new(wavelengths, absorbance)
  end

  describe "Mode.absorbance_at/2" do
    test "finds absorbance at exact wavelength" do
      spectrum = %{
        wavelengths: [250.0, 260.0, 270.0],
        absorbance: [0.1, 0.5, 0.2]
      }

      assert Mode.absorbance_at(spectrum, 260.0) == 0.5
    end

    test "finds absorbance at nearest wavelength" do
      spectrum = %{
        wavelengths: [250.0, 260.0, 270.0],
        absorbance: [0.1, 0.5, 0.2]
      }

      # 261 is closer to 260 than 270
      assert Mode.absorbance_at(spectrum, 261.0) == 0.5
    end

    test "uses corrected_absorbance if available" do
      spectrum = %{
        wavelengths: [250.0, 260.0, 270.0],
        absorbance: [0.1, 0.5, 0.2],
        corrected_absorbance: [0.05, 0.4, 0.15]
      }

      assert Mode.absorbance_at(spectrum, 260.0) == 0.4
    end
  end

  describe "Mode.safe_ratio/2" do
    test "computes ratio normally" do
      assert Mode.safe_ratio(1.8, 1.0) == 1.8
    end

    test "returns nil for near-zero denominator" do
      assert Mode.safe_ratio(1.0, 0.0005) == nil
      assert Mode.safe_ratio(1.0, 0.0) == nil
      assert Mode.safe_ratio(1.0, -0.0005) == nil
    end

    test "works with negative values" do
      assert Mode.safe_ratio(-1.0, 2.0) == -0.5
    end
  end

  describe "DNA.metadata/2" do
    test "computes corrected absorbance values" do
      spectrum = sample_spectrum()
      mode = %DNA{}

      metadata = Mode.metadata(mode, spectrum)

      assert is_float(metadata.a260)
      assert is_float(metadata.a280)
      assert is_float(metadata.concentration_ng_ul)
      assert metadata.concentration_ng_ul == metadata.a260 * 50.0
    end

    test "computes ratios" do
      spectrum = sample_spectrum()
      mode = %DNA{}

      metadata = Mode.metadata(mode, spectrum)

      assert is_float(metadata.a260_a280) or is_nil(metadata.a260_a280)
      assert is_float(metadata.a260_a230) or is_nil(metadata.a260_a230)
    end

    test "includes raw values for comparison" do
      spectrum = sample_spectrum()
      mode = %DNA{}

      metadata = Mode.metadata(mode, spectrum)

      assert is_float(metadata.raw_a260)
      assert is_float(metadata.raw_a280)
      assert is_float(metadata.raw_concentration)
    end

    test "includes private baseline data" do
      spectrum = sample_spectrum()
      mode = %DNA{}

      metadata = Mode.metadata(mode, spectrum)

      assert is_list(metadata._baseline)
      assert %Spectrum{} = metadata._corrected_spectrum
      assert %Nanodrop.Functions.Turbidity{} = metadata._turbidity
    end

    test "respects custom factor" do
      spectrum = sample_spectrum()
      mode = %DNA{factor: 33.0}

      metadata = Mode.metadata(mode, spectrum)

      assert metadata.concentration_ng_ul == metadata.a260 * 33.0
    end
  end

  describe "DNA.overlays/3" do
    test "generates SVG string" do
      spectrum = sample_spectrum()
      mode = %DNA{}
      metadata = Mode.metadata(mode, spectrum)

      context = %{
        scale_x: fn wl -> (wl - 220) * 2 end,
        scale_y: fn abs -> 200 - abs * 100 end,
        x_off: 50,
        y_off: 50,
        width: 300,
        height: 200,
        baseline_path: "M 0,0 L 100,100"
      }

      overlay = Mode.overlays(mode, metadata, context)

      assert is_binary(overlay)
      assert overlay =~ "230"
      assert overlay =~ "260"
      assert overlay =~ "280"
      assert overlay =~ "ng/µL"
    end
  end
end
