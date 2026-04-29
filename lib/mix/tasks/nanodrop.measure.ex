defmodule Mix.Tasks.Nanodrop.Measure do
  @moduledoc """
  Measure DNA concentration for samples with graphs.

  ## Usage

      mix nanodrop.measure [NUM_SAMPLES]

  NUM_SAMPLES defaults to 3 if not specified.
  Generates dna_spectra.png with absorbance plots and baseline correction.

  ## Example

      mix nanodrop.measure 5
  """

  use Mix.Task

  @shortdoc "Measure DNA concentration"

  @impl Mix.Task
  def run(args) do
    num_samples = parse_args(args)

    Mix.Task.run("app.start")

    {:ok, pid} = Nanodrop.start_link()
    IO.puts("Device: #{Nanodrop.serial_number(pid)}")

    IO.puts("\nPut WATER on pedestal, close arm, press Enter for calibration...")
    IO.read(:stdio, :line)

    IO.puts("Calibrating...")

    case Nanodrop.calibrate(pid) do
      :ok ->
        IO.puts("Calibration OK")
        results = measure_samples(pid, num_samples)
        Nanodrop.Graph.save(results, "dna_spectra.png")
        IO.puts("Graph saved to dna_spectra.png")

      {:error, {:calibration_failed, :low_blank_intensity, intensity}} ->
        Mix.raise(
          "Calibration FAILED: blank intensity #{intensity} < 2500 - strobe may not have fired"
        )

      {:error, reason} ->
        Mix.raise("Calibration FAILED: #{inspect(reason)}")
    end

    IO.puts("\nDone.")
  end

  defp parse_args([]), do: 3

  defp parse_args([n | _]) do
    case Integer.parse(n) do
      {num, _} when num > 0 -> num
      _ -> Mix.raise("Invalid number of samples: #{n}")
    end
  end

  defp measure_samples(pid, num_samples) do
    for i <- 1..num_samples do
      IO.puts("\nWipe, put SAMPLE #{i} on pedestal, close arm, press Enter...")
      IO.read(:stdio, :line)

      IO.puts("Measuring...")
      {:ok, result} = Nanodrop.measure_nucleic_acid(pid)

      IO.puts("\n  Sample #{i} Results:")
      IO.puts("    A260: #{Float.round(result.a260, 3)}")
      IO.puts("    A280: #{Float.round(result.a280, 3)}")
      IO.puts("    A260/A280: #{format_ratio(result.a260_a280)}")
      IO.puts("    A260/A230: #{format_ratio(result.a260_a230)}")
      IO.puts("    Concentration: #{Float.round(result.concentration_ng_ul, 1)} ng/uL")

      %{
        sample: i,
        a260: result.a260,
        a280: result.a280,
        a260_a280: result.a260_a280,
        a260_a230: result.a260_a230,
        concentration_ng_ul: result.concentration_ng_ul,
        wavelengths: result.spectrum.wavelengths,
        absorbance: result.spectrum.absorbance
      }
    end
  end

  defp format_ratio(nil), do: "N/A"
  defp format_ratio(ratio), do: Float.round(ratio, 2)
end
