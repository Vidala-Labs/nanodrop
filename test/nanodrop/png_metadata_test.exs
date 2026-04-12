defmodule Nanodrop.PngMetadataTest do
  use ExUnit.Case

  alias Nanodrop.Graph
  alias Nanodrop.Mode.DNA
  alias Vix.Vips.Image

  @fixture_path "test/fixtures/spectrum_20260412_015908.json"

  setup do
    fixture = File.read!(@fixture_path) |> Jason.decode!()

    result = %{
      sample: 1,
      wavelengths: fixture["wavelengths"],
      absorbance: fixture["absorbance"],
      a260: fixture["a260"],
      a280: fixture["a280"],
      ratio: fixture["a260_a280"],
      concentration: fixture["concentration_ng_ul"]
    }

    {:ok, result: result, fixture: fixture}
  end

  describe "generate_png/3 metadata" do
    test "embeds spectrum data in PNG comment", %{result: result} do
      metadata = %{
        timestamp: "2026-04-11T10:30:00Z",
        assay: "dna",
        a260_a230: 2.1
      }

      {:ok, png_binary} = Graph.generate_png([result], %DNA{}, metadata: metadata)

      # Load the PNG and extract metadata
      {:ok, image} = Image.new_from_buffer(png_binary)
      {:ok, comment} = Image.header_value(image, "png-comment-0-Spectrum")

      # Parse the JSON metadata
      metadata_json = Jason.decode!(comment)

      # Verify top-level structure
      assert Map.has_key?(metadata_json, "data")
      assert Map.has_key?(metadata_json, "units")
      assert Map.has_key?(metadata_json, "metadata")
    end

    test "data array contains x/y pairs for wavelength/absorbance", %{result: result} do
      {:ok, png_binary} = Graph.generate_png([result], %DNA{})
      {:ok, image} = Image.new_from_buffer(png_binary)
      {:ok, comment} = Image.header_value(image, "png-comment-0-Spectrum")

      metadata_json = Jason.decode!(comment)
      data = metadata_json["data"]

      # Should have same number of points as wavelengths
      assert length(data) == length(result.wavelengths)

      # Each point should have x and y
      first_point = List.first(data)
      assert Map.has_key?(first_point, "x")
      assert Map.has_key?(first_point, "y")

      # Values should match input
      assert first_point["x"] == List.first(result.wavelengths)
      assert first_point["y"] == List.first(result.absorbance)
    end

    test "units specify nm for x axis and nil for y", %{result: result} do
      {:ok, png_binary} = Graph.generate_png([result], %DNA{})
      {:ok, image} = Image.new_from_buffer(png_binary)
      {:ok, comment} = Image.header_value(image, "png-comment-0-Spectrum")

      metadata_json = Jason.decode!(comment)
      units = metadata_json["units"]

      assert units["x"] == "nm"
      assert units["y"] == nil
    end

    test "metadata contains a260 concentration", %{result: result} do
      {:ok, png_binary} = Graph.generate_png([result], %DNA{})
      {:ok, image} = Image.new_from_buffer(png_binary)
      {:ok, comment} = Image.header_value(image, "png-comment-0-Spectrum")

      metadata_json = Jason.decode!(comment)
      meta = metadata_json["metadata"]

      assert meta["a260"] == result.concentration
    end

    test "metadata contains a260_a280 ratio", %{result: result} do
      {:ok, png_binary} = Graph.generate_png([result], %DNA{})
      {:ok, image} = Image.new_from_buffer(png_binary)
      {:ok, comment} = Image.header_value(image, "png-comment-0-Spectrum")

      metadata_json = Jason.decode!(comment)
      meta = metadata_json["metadata"]

      assert meta["a260_a280"] == result.ratio
    end

    test "metadata contains optional a260_a230 when provided", %{result: result} do
      metadata = %{a260_a230: 2.15}

      {:ok, png_binary} = Graph.generate_png([result], %DNA{}, metadata: metadata)
      {:ok, image} = Image.new_from_buffer(png_binary)
      {:ok, comment} = Image.header_value(image, "png-comment-0-Spectrum")

      metadata_json = Jason.decode!(comment)
      meta = metadata_json["metadata"]

      assert meta["a260_a230"] == 2.15
    end

    test "metadata contains timestamp when provided", %{result: result} do
      timestamp = "2026-04-11T10:30:00Z"
      metadata = %{timestamp: timestamp}

      {:ok, png_binary} = Graph.generate_png([result], %DNA{}, metadata: metadata)
      {:ok, image} = Image.new_from_buffer(png_binary)
      {:ok, comment} = Image.header_value(image, "png-comment-0-Spectrum")

      metadata_json = Jason.decode!(comment)
      meta = metadata_json["metadata"]

      assert meta["timestamp"] == timestamp
    end

    test "metadata contains assay type when provided", %{result: result} do
      metadata = %{assay: "dna"}

      {:ok, png_binary} = Graph.generate_png([result], %DNA{}, metadata: metadata)
      {:ok, image} = Image.new_from_buffer(png_binary)
      {:ok, comment} = Image.header_value(image, "png-comment-0-Spectrum")

      metadata_json = Jason.decode!(comment)
      meta = metadata_json["metadata"]

      assert meta["assay"] == "dna"
    end

    test "metadata fields are nil when not provided", %{result: result} do
      {:ok, png_binary} = Graph.generate_png([result], %DNA{})
      {:ok, image} = Image.new_from_buffer(png_binary)
      {:ok, comment} = Image.header_value(image, "png-comment-0-Spectrum")

      metadata_json = Jason.decode!(comment)
      meta = metadata_json["metadata"]

      assert meta["a260_a230"] == nil
      assert meta["timestamp"] == nil
      assert meta["assay"] == nil
    end
  end
end
