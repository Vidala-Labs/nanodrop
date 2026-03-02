defmodule Nanodrop.Spectrum do
  @moduledoc """
  Spectrum data structure and analysis functions.

  The USB2000 in the NanoDrop returns 2048 pixel values representing
  light intensity across the detector. The wavelength for each pixel
  is calculated using calibration coefficients stored on the device.

  ## Wavelength Calculation

  The wavelength for pixel N is calculated as:

      λ(N) = C0 + C1*N + C2*N² + C3*N³

  Where C0-C3 are the wavelength calibration coefficients.

  ## Dark Pixels

  Pixels 2-24 are "dark pixels" - they are optically masked and provide
  a baseline for dark current subtraction.
  """

  @num_pixels 2048
  @dark_pixel_start 2
  @dark_pixel_end 24

  @type t :: %__MODULE__{
          raw_pixels: [non_neg_integer()],
          timestamp: DateTime.t(),
          calibration: calibration() | nil
        }

  @type calibration :: %{
          intercept: float(),
          first_coefficient: float(),
          second_coefficient: float(),
          third_coefficient: float()
        }

  defstruct [
    :raw_pixels,
    :timestamp,
    :calibration
  ]

  @doc """
  Creates a Spectrum struct from raw binary data.

  The data should be 4096 bytes (2048 x 16-bit little-endian values).
  """
  @spec from_raw(binary()) :: t()
  def from_raw(data) when byte_size(data) >= @num_pixels * 2 do
    pixels = decode_pixels(data)

    %__MODULE__{
      raw_pixels: pixels,
      timestamp: DateTime.utc_now(),
      calibration: nil
    }
  end

  @doc """
  Attaches calibration data to a spectrum.
  """
  @spec with_calibration(t(), calibration()) :: t()
  def with_calibration(spectrum, calibration) do
    %{spectrum | calibration: calibration}
  end

  @doc """
  Returns the dark pixel values (pixels 2-24).
  """
  @spec dark_pixels(t()) :: [non_neg_integer()]
  def dark_pixels(%__MODULE__{raw_pixels: pixels}) do
    Enum.slice(pixels, @dark_pixel_start, @dark_pixel_end - @dark_pixel_start + 1)
  end

  @doc """
  Calculates the average dark pixel value for baseline subtraction.
  """
  @spec dark_average(t()) :: float()
  def dark_average(spectrum) do
    dark = dark_pixels(spectrum)
    Enum.sum(dark) / length(dark)
  end

  @doc """
  Returns the active pixel values (excluding dark pixels).
  """
  @spec active_pixels(t()) :: [non_neg_integer()]
  def active_pixels(%__MODULE__{raw_pixels: pixels}) do
    Enum.drop(pixels, @dark_pixel_end + 1)
  end

  @doc """
  Calculates the wavelength for a given pixel index.

  Requires calibration data to be attached to the spectrum.
  """
  @spec wavelength_at(t(), non_neg_integer()) :: float() | {:error, :no_calibration}
  def wavelength_at(%__MODULE__{calibration: nil}, _pixel_index) do
    {:error, :no_calibration}
  end

  def wavelength_at(%__MODULE__{calibration: cal}, pixel_index) do
    n = pixel_index

    cal.intercept +
      cal.first_coefficient * n +
      cal.second_coefficient * n * n +
      cal.third_coefficient * n * n * n
  end

  @doc """
  Returns all wavelength/intensity pairs for the spectrum.

  Requires calibration data to be attached.
  """
  @spec to_wavelength_intensity_pairs(t()) ::
          [{wavelength :: float(), intensity :: non_neg_integer()}] | {:error, :no_calibration}
  def to_wavelength_intensity_pairs(%__MODULE__{calibration: nil}) do
    {:error, :no_calibration}
  end

  def to_wavelength_intensity_pairs(%__MODULE__{raw_pixels: pixels} = spectrum) do
    pixels
    |> Enum.with_index()
    |> Enum.map(fn {intensity, index} ->
      {wavelength_at(spectrum, index), intensity}
    end)
  end

  @doc """
  Applies dark subtraction to the spectrum.

  Subtracts the average dark pixel value from all pixel values.
  """
  @spec dark_subtract(t()) :: t()
  def dark_subtract(%__MODULE__{raw_pixels: pixels} = spectrum) do
    dark_avg = dark_average(spectrum)

    corrected =
      Enum.map(pixels, fn value ->
        max(0, round(value - dark_avg))
      end)

    %{spectrum | raw_pixels: corrected}
  end

  @doc """
  Finds the pixel index with maximum intensity.
  """
  @spec peak_pixel(t()) :: non_neg_integer()
  def peak_pixel(%__MODULE__{raw_pixels: pixels}) do
    pixels
    |> Enum.with_index()
    |> Enum.max_by(fn {value, _index} -> value end)
    |> elem(1)
  end

  @doc """
  Returns the intensity at a specific wavelength (interpolated).

  Requires calibration data.
  """
  @spec intensity_at_wavelength(t(), float()) :: float() | {:error, :no_calibration}
  def intensity_at_wavelength(%__MODULE__{calibration: nil}, _wavelength) do
    {:error, :no_calibration}
  end

  def intensity_at_wavelength(%__MODULE__{raw_pixels: pixels} = spectrum, wavelength) do
    # Find the two pixels that bracket this wavelength
    wavelengths = Enum.map(0..(@num_pixels - 1), &wavelength_at(spectrum, &1))

    case find_bracketing_indices(wavelengths, wavelength) do
      {:ok, lower, upper} ->
        # Linear interpolation
        w1 = Enum.at(wavelengths, lower)
        w2 = Enum.at(wavelengths, upper)
        i1 = Enum.at(pixels, lower)
        i2 = Enum.at(pixels, upper)

        fraction = (wavelength - w1) / (w2 - w1)
        i1 + fraction * (i2 - i1)

      :error ->
        {:error, :wavelength_out_of_range}
    end
  end

  # Private functions

  defp decode_pixels(data) do
    decode_pixels(data, [])
  end

  defp decode_pixels(<<value::little-16, rest::binary>>, acc) do
    decode_pixels(rest, [value | acc])
  end

  defp decode_pixels(<<>>, acc), do: Enum.reverse(acc)
  defp decode_pixels(_, acc), do: Enum.reverse(acc)

  defp find_bracketing_indices(wavelengths, target) do
    indexed = Enum.with_index(wavelengths)

    case Enum.find(indexed, fn {w, _i} -> w >= target end) do
      nil -> :error
      {_, 0} -> :error
      {_, upper} -> {:ok, upper - 1, upper}
    end
  end
end
