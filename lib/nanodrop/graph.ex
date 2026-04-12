defmodule Nanodrop.Graph do
  @moduledoc """
  Generates SVG graphs for spectral data.
  """

  require EEx

  alias Nanodrop.Mode
  alias Nanodrop.Spectrum
  alias Vix.Vips.Image
  alias Vix.Vips.MutableImage

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

  @doc """
  Generates a PNG binary with embedded metadata.

  Returns `{:ok, png_binary}` or `{:error, reason}`.

  The PNG includes spectrum data as JSON in the png-comment chunk.
  Additional metadata can be passed in the `metadata` option.

  ## Options

  - `:metadata` - Additional metadata map to merge into the embedded JSON

  ## Example

      result = %{
        sample: 1,
        wavelengths: [...],
        absorbance: [...],
        a260: 1.5,
        a280: 0.8,
        ratio: 1.87,
        concentration: 75.0
      }
      {:ok, png} = Nanodrop.Graph.generate_png([result], %Nanodrop.Mode.DNA{},
        metadata: %{timestamp: "2026-04-11T10:30:00Z", device_serial: "ABC123"}
      )
  """
  @spec generate_png(list(map()), struct(), keyword()) :: {:ok, binary()} | {:error, term()}
  def generate_png(results, mode \\ %Nanodrop.Mode.DNA{}, opts \\ []) do
    svg = generate(results, mode)
    extra_metadata = Keyword.get(opts, :metadata, %{})

    try do
      {:ok, image} = Image.new_from_buffer(svg)

      # Embed spectrum data as JSON in PNG comment
      spectrum_data = encode_spectrum_metadata(results, extra_metadata)

      {:ok, image_with_meta} =
        Image.mutate(image, fn mut_image ->
          :ok = MutableImage.set(mut_image, "png-comment-0-Spectrum", :gchararray, spectrum_data)
        end)

      {:ok, png_binary} = Image.write_to_buffer(image_with_meta, ".png")
      {:ok, png_binary}
    rescue
      e -> {:error, e}
    end
  end

  defp save_png(svg, filename, results) do
    {:ok, image} = Image.new_from_buffer(svg)

    # Embed spectrum data as JSON in PNG comment
    spectrum_data = encode_spectrum_metadata(results, %{})

    {:ok, image_with_meta} =
      Image.mutate(image, fn mut_image ->
        :ok = MutableImage.set(mut_image, "png-comment-0-Spectrum", :gchararray, spectrum_data)
      end)

    :ok = Image.write_to_file(image_with_meta, filename)
  end

  defp encode_spectrum_metadata(results, extra_metadata) do
    # Build data array from first result (single measurement)
    result = List.first(results)

    data =
      Enum.zip(result.wavelengths, result.absorbance)
      |> Enum.map(fn {wl, abs} -> %{x: wl, y: abs} end)

    %{
      data: data,
      units: %{x: "nm", y: nil},
      metadata: %{
        a260: result.concentration,
        a260_a230: extra_metadata[:a260_a230],
        a260_a280: result.ratio,
        timestamp: extra_metadata[:timestamp],
        assay: extra_metadata[:assay]
      }
    }
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

    # Calculate y-axis range from data
    all_abs = raw_abs ++ baseline_abs
    data_min = Enum.min(all_abs)
    data_max = Enum.max(all_abs)

    # Use actual data range for scaling
    min_abs = data_min
    max_abs = data_max * 1.1

    # Generate y-axis ticks - labels start at 0, showing offset from minimum
    display_range = max_abs - min_abs
    nice_step = nice_tick_step(display_range)

    # Generate ticks: 0, step, 2*step, ... up to display_range
    y_ticks =
      Stream.iterate(0.0, &(&1 + nice_step))
      |> Stream.take_while(fn label -> label <= display_range * 1.01 end)
      |> Enum.map(fn label ->
        {Float.round(label, 2), min_abs + label}  # {display_label, actual_value}
      end)

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
      overlay: overlay,
      y_ticks: Enum.map(y_ticks, fn {label, actual_val} -> {label, scale_y.(actual_val)} end)
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

  defp nice_tick_step(range) do
    # Aim for ~5 ticks, round to nice values (0.05, 0.1, 0.2, 0.5, etc.)
    raw_step = range / 5
    magnitude = :math.pow(10, :math.floor(:math.log10(raw_step)))
    normalized = raw_step / magnitude

    cond do
      normalized <= 1.0 -> 1.0 * magnitude
      normalized <= 2.0 -> 2.0 * magnitude
      normalized <= 5.0 -> 5.0 * magnitude
      true -> 10.0 * magnitude
    end
  end
end
