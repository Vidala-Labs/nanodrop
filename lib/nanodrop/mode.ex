use Protoss

defprotocol Nanodrop.Mode do
  @moduledoc """
  Protocol for measurement modes (DNA, Protein, etc.).

  Each mode defines how to extract metadata from a spectrum and
  generate SVG overlays for visualization.
  """

  @doc """
  Extract metadata from a spectrum for this mode.

  Returns a map of key-value pairs. Keys starting with underscore
  are considered private/internal (e.g., `_baseline`, `_corrected_absorbance`).
  """
  def metadata(mode, spectrum)

  @doc """
  Generate SVG overlay elements from metadata.

  The context map contains:
  - `:scale_x` - function to convert wavelength to x pixel
  - `:scale_y` - function to convert absorbance to y pixel
  - `:x_off`, `:y_off` - chart offsets
  - `:width`, `:height` - chart dimensions

  Returns an SVG string to be inserted into the graph.
  """
  def overlays(mode, metadata, context)
after
  @doc """
  Find the absorbance value at a specific wavelength.

  If the spectrum has `:corrected_absorbance`, uses that. Otherwise uses `:absorbance`.
  """
  @spec absorbance_at(map(), float()) :: float()
  def absorbance_at(spectrum, target_wavelength) do
    wavelengths = spectrum.wavelengths
    absorbance = spectrum[:corrected_absorbance] || spectrum.absorbance

    idx =
      wavelengths
      |> Enum.with_index()
      |> Enum.min_by(fn {wl, _} -> abs(wl - target_wavelength) end)
      |> elem(1)

    Enum.at(absorbance, idx)
  end

  @doc """
  Safely compute a ratio, returning nil if denominator is zero or near-zero.
  """
  @spec safe_ratio(float(), float()) :: float() | nil
  def safe_ratio(_, denom) when abs(denom) < 0.001, do: nil
  def safe_ratio(num, denom), do: num / denom
end
