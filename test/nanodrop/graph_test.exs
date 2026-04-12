defmodule Nanodrop.GraphTest do
  use ExUnit.Case

  alias Nanodrop.Graph
  alias Nanodrop.Mode.DNA

  # Sample result data matching what the mix task produces
  defp sample_result(sample_num) do
    wavelengths = Enum.map(220..400, &(&1 * 1.0))

    absorbance =
      Enum.map(wavelengths, fn wl ->
        peak = :math.exp(-:math.pow(wl - 260, 2) / 500)
        baseline = 0.1 + (400 - wl) * 0.0005
        peak * 0.5 + baseline
      end)

    %{
      sample: sample_num,
      wavelengths: wavelengths,
      absorbance: absorbance
    }
  end

  describe "generate/2" do
    test "generates valid SVG with DNA mode" do
      results = [sample_result(1)]
      mode = %DNA{}

      svg = Graph.generate(results, mode)

      assert svg =~ "<?xml"
      assert svg =~ "<svg"
      assert svg =~ "</svg>"
      assert svg =~ "Sample 1"
    end

    test "defaults to DNA mode" do
      results = [sample_result(1)]

      svg = Graph.generate(results)

      # Should contain DNA-specific overlays
      assert svg =~ "260"
      assert svg =~ "280"
      assert svg =~ "ng/µL"
    end

    test "generates multiple charts" do
      results = [sample_result(1), sample_result(2), sample_result(3)]

      svg = Graph.generate(results)

      assert svg =~ "Sample 1"
      assert svg =~ "Sample 2"
      assert svg =~ "Sample 3"
    end

    test "includes baseline path" do
      results = [sample_result(1)]

      svg = Graph.generate(results)

      # Baseline is orange dashed in DNA overlay
      assert svg =~ "stroke=\"orange\""
      assert svg =~ "stroke-dasharray"
    end

    test "includes wavelength markers" do
      results = [sample_result(1)]

      svg = Graph.generate(results)

      assert svg =~ "230"
      assert svg =~ "260"
      assert svg =~ "280"
    end

    test "uses custom DNA factor" do
      results = [sample_result(1)]
      mode = %DNA{factor: 33.0}  # ssDNA factor

      svg = Graph.generate(results, mode)

      # Should still generate valid SVG
      assert svg =~ "<svg"
      assert svg =~ "ng/µL"
    end
  end

  describe "save/3" do
    @tag :tmp_dir
    test "saves SVG file", %{tmp_dir: tmp_dir} do
      results = [sample_result(1)]
      path = Path.join(tmp_dir, "test.svg")

      :ok = Graph.save(results, path)

      assert File.exists?(path)
      content = File.read!(path)
      assert content =~ "<svg"
    end
  end
end
