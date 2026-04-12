defmodule Nanodrop.Graph do
  @moduledoc """
  Generates SVG graphs for spectral data.
  """

  require EEx

  alias Nanodrop.Mode
  alias Nanodrop.Spectrum

  @chart_width 300
  @chart_height 200
  @margin 50

  EEx.function_from_file(:defp, :svg_template, "lib/nanodrop/templates/spectrum.svg.eex", [
    :assigns
  ])

  @doc """
  Generates an SVG graph from measurement results.

  ## Parameters

  - `results` - List of measurement result maps containing:
    - `:sample` - Sample number
    - `:wavelengths` - List of wavelengths
    - `:absorbance` - List of absorbance values
  - `mode` - A Nanodrop.Mode implementation (e.g., `%Nanodrop.Mode.DNA{}`)

  ## Returns

  SVG string.
  """
  @spec generate(list(map()), struct()) :: String.t()
  def generate(results, mode \\ %Nanodrop.Mode.DNA{}) do
    num = length(results)
    total_width = num * (@chart_width + @margin) + @margin
    total_height = @chart_height + 120

    charts =
      results
      |> Enum.with_index()
      |> Enum.map(fn {result, idx} ->
        x_offset = @margin + idx * (@chart_width + @margin)
        build_chart_data(result, mode, x_offset, 50, @chart_width, @chart_height)
      end)

    assigns = %{
      total_width: total_width,
      total_height: total_height,
      charts: charts
    }

    svg_template(assigns)
  end

  @doc """
  Generates an SVG graph and saves to file.

  If filename ends in `.png`, converts SVG to PNG using Vix/libvips.
  Otherwise saves as SVG.

  PNG files include spectrum data as metadata (JSON in png-comment chunk).
  """
  @spec save(list(map()), String.t(), struct()) :: :ok
  def save(results, filename, mode \\ %Nanodrop.Mode.DNA{}) do
    svg = generate(results, mode)

    if String.ends_with?(filename, ".png") do
      save_png(svg, filename, results)
    else
      File.write!(filename, svg)
    end

    :ok
  end

  defp save_png(svg, filename, results) do
    alias Vix.Vips.{Image, MutableImage}

    {:ok, image} = Image.new_from_buffer(svg)

    # Embed spectrum data as JSON in PNG comment
    spectrum_data = encode_spectrum_metadata(results)

    {:ok, image_with_meta} =
      Image.mutate(image, fn mut_image ->
        :ok = MutableImage.set(mut_image, "png-comment-0-Spectrum", :gchararray, spectrum_data)
      end)

    :ok = Image.write_to_file(image_with_meta, filename)
  end

  defp encode_spectrum_metadata(results) do
    results
    |> Enum.map(fn result ->
      spectrum =
        result.wavelengths
        |> Enum.map(&to_string/1)
        |> Enum.zip(result.absorbance)
        |> Map.new()

      %{
        sample: result.sample,
        a260: result.a260,
        a280: result.a280,
        ratio: result.ratio,
        concentration_ng_ul: result.concentration,
        spectrum: spectrum
      }
    end)
    |> Jason.encode!()
  end

  defp build_chart_data(result, mode, x_off, y_off, width, height) do
    # Build spectrum struct and get metadata from mode
    spectrum = Spectrum.new(result.wavelengths, result.absorbance)
    metadata = Mode.metadata(mode, spectrum)

    # Filter to 220-400nm range
    indices =
      result.wavelengths
      |> Enum.with_index()
      |> Enum.filter(fn {wl, _} -> wl >= 220 and wl <= 400 end)
      |> Enum.map(fn {_, idx} -> idx end)

    wavelengths = Enum.map(indices, &Enum.at(result.wavelengths, &1))
    raw_abs = Enum.map(indices, &Enum.at(result.absorbance, &1))
    baseline_abs = Enum.map(indices, &Enum.at(metadata._baseline, &1))

    min_wl = 220
    max_wl = 400
    min_abs = 0
    max_abs = max(Enum.max(raw_abs), 0.5) * 1.1

    # Scale functions
    scale_x = fn wl -> x_off + (wl - min_wl) / (max_wl - min_wl) * width end
    scale_y = fn abs -> y_off + height - (abs - min_abs) / (max_abs - min_abs) * height end

    # Generate paths
    raw_path = build_path(wavelengths, raw_abs, scale_x, scale_y)
    baseline_path = build_path(wavelengths, baseline_abs, scale_x, scale_y)

    # Build context for mode overlays
    context = %{
      scale_x: scale_x,
      scale_y: scale_y,
      x_off: x_off,
      y_off: y_off,
      width: width,
      height: height,
      baseline_path: baseline_path
    }

    overlay = Mode.overlays(mode, metadata, context)

    %{
      x_off: x_off,
      y_off: y_off,
      width: width,
      height: height,
      raw_path: raw_path,
      sample: result.sample,
      overlay: overlay
    }
  end

  defp build_path(wavelengths, absorbances, scale_x, scale_y) do
    Enum.zip(wavelengths, absorbances)
    |> Enum.map(fn {wl, abs} ->
      "#{Float.round(scale_x.(wl), 1)},#{Float.round(scale_y.(abs), 1)}"
    end)
    |> Enum.join(" L ")
    |> then(&("M " <> &1))
  end
end
