defmodule Nanodrop.Mode.DNA do
  @moduledoc """
  DNA/RNA measurement mode.

  Measures nucleic acid concentration using A260 absorbance with
  Rayleigh scattering turbidity baseline correction.

  ## Factors

  - dsDNA: 50 ng/µL per A260
  - ssDNA: 33 ng/µL per A260
  - RNA: 40 ng/µL per A260
  """

  defstruct factor: 50.0,
            center: 260.0

  @type t :: %__MODULE__{
          factor: float(),
          center: float()
        }

  use Nanodrop.Mode

  require EEx

  EEx.function_from_file(:defp, :overlay_template, "lib/nanodrop/templates/dna_overlay.svg.eex", [
    :assigns
  ])

  @impl Nanodrop.Mode
  def metadata(%__MODULE__{} = mode, spectrum) do
    alias Nanodrop.Baseline
    alias Nanodrop.Functions.Turbidity

    # Apply turbidity baseline correction
    {_original, corrected_spectrum, turbidity} = Baseline.correct(spectrum)

    # Calculate key wavelength absorbances from corrected spectrum
    a230 = Nanodrop.Mode.absorbance_at(corrected_spectrum, 230.0)
    a260 = Nanodrop.Mode.absorbance_at(corrected_spectrum, 260.0)
    a280 = Nanodrop.Mode.absorbance_at(corrected_spectrum, 280.0)
    a320 = Nanodrop.Mode.absorbance_at(corrected_spectrum, 320.0)

    # For A260/A230, use asymptotic baseline (b) only - as λ→∞, baseline→b
    # This removes constant offset but not wavelength-dependent scattering
    raw_a230 = Nanodrop.Mode.absorbance_at(spectrum, 230.0)
    raw_a260 = Nanodrop.Mode.absorbance_at(spectrum, 260.0)
    raw_a280 = Nanodrop.Mode.absorbance_at(spectrum, 280.0)
    a260_asymp = raw_a260 - turbidity.b
    a230_asymp = raw_a230 - turbidity.b

    # Compute baseline from turbidity parameters
    wavelengths = spectrum.wavelengths
    baseline = Turbidity.evaluate_all(turbidity, wavelengths)

    %{
      a230: a230,
      a260: a260,
      a280: a280,
      a320: a320,
      a260_a280: Nanodrop.Mode.safe_ratio(a260, a280),
      a260_a230: Nanodrop.Mode.safe_ratio(a260_asymp, a230_asymp),
      concentration_ng_ul: a260 * mode.factor,
      raw_a260: raw_a260,
      raw_a280: raw_a280,
      raw_a260_a280: Nanodrop.Mode.safe_ratio(raw_a260, raw_a280),
      raw_concentration: raw_a260 * mode.factor,
      _turbidity: turbidity,
      _corrected_spectrum: corrected_spectrum,
      _baseline: baseline
    }
  end

  @impl Nanodrop.Mode
  def overlays(%__MODULE__{}, metadata, context) do
    assigns = %{meta: metadata, ctx: context}
    overlay_template(assigns)
  end

  defp format_ratio(nil), do: "N/A"
  defp format_ratio(ratio), do: Float.round(ratio, 2)
end
