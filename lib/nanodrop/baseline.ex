defmodule Nanodrop.Baseline do
  @moduledoc """
  Baseline correction using Rayleigh scattering turbidity model.

  Fits turbidity baseline to:

      baseline(λ) = a·λ^(-4) + b

  Using least-squares fit over two segments where peak contribution is minimal:
  - 220-230nm (left edge)
  - 300-400nm (right side)

  The corrected spectrum is simply: raw - baseline
  A260 is read directly from the corrected spectrum.
  """

  alias Nanodrop.Functions.Turbidity
  alias Nanodrop.Spectrum

  @n 4.0  # Rayleigh scattering exponent (fixed)

  @doc """
  Corrects a spectrum for baseline using Rayleigh turbidity fit.

  Returns a tuple of `{spectrum, corrected_spectrum, turbidity}`:
  - `spectrum` - the original input spectrum
  - `corrected_spectrum` - baseline-subtracted spectrum
  - `turbidity` - fitted turbidity parameters (%Turbidity{})
  """
  @spec correct(Spectrum.t(), keyword()) :: {Spectrum.t(), Spectrum.t(), Turbidity.t()}
  def correct(%Spectrum{} = spectrum, _opts \\ []) do
    wavelengths = spectrum.wavelengths
    absorbance = spectrum.absorbance

    # Fit turbidity using two segments: 220-230nm and 300-400nm
    turbidity = fit_turbidity(wavelengths, absorbance)

    # Calculate baseline
    baseline = Turbidity.evaluate_all(turbidity, wavelengths)

    # Corrected = raw - baseline
    corrected_absorbance =
      Enum.zip(absorbance, baseline)
      |> Enum.map(fn {abs, bl} -> abs - bl end)

    corrected_spectrum = %Spectrum{
      wavelengths: wavelengths,
      absorbance: corrected_absorbance,
      timestamp: spectrum.timestamp
    }

    {spectrum, corrected_spectrum, turbidity}
  end

  @doc """
  Fits turbidity parameters using least-squares over two segments.

  Segments: 220-230nm and 300-400nm (away from 260nm peak)
  Model: A(λ) = a·λ^(-4) + b
  """
  def fit_turbidity(wavelengths, absorbance) do
    # Extract data points from the two segments
    data = Enum.zip(wavelengths, absorbance)

    segment_data =
      data
      |> Enum.filter(fn {wl, _} ->
        (wl >= 220.0 and wl <= 230.0) or (wl >= 300.0 and wl <= 400.0)
      end)

    # Least squares fit: A = a·λ^(-4) + b
    # Let x = λ^(-4), then A = a·x + b
    # This is linear regression: minimize Σ(A - a·x - b)²

    {sum_x, sum_y, sum_xx, sum_xy, n} =
      Enum.reduce(segment_data, {0.0, 0.0, 0.0, 0.0, 0}, fn {wl, abs}, {sx, sy, sxx, sxy, count} ->
        x = :math.pow(wl, -@n)
        {sx + x, sy + abs, sxx + x * x, sxy + x * abs, count + 1}
      end)

    # Solve normal equations:
    # a = (n·Σxy - Σx·Σy) / (n·Σx² - (Σx)²)
    # b = (Σy - a·Σx) / n
    denom = n * sum_xx - sum_x * sum_x

    a = if denom != 0.0, do: (n * sum_xy - sum_x * sum_y) / denom, else: 0.0
    b = (sum_y - a * sum_x) / n

    %Turbidity{a: a, n: @n, b: b}
  end
end
