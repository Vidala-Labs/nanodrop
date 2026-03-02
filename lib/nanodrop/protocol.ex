defmodule Nanodrop.Protocol do
  @moduledoc """
  Ocean Optics Interface (OOI) protocol implementation.

  This module implements the USB2000 command protocol for communicating
  with NanoDrop spectrophotometers.

  ## Command Reference

  | Command | Hex  | Description |
  |---------|------|-------------|
  | Initialize | 0x01 | Initialize spectrometer |
  | Set Integration Time | 0x02 | Set integration time in µs |
  | Set Strobe Enable | 0x03 | Enable/disable strobe |
  | Set Shutdown Mode | 0x04 | Enter low-power mode |
  | Query Information | 0x05 | Query device info/calibration |
  | Write Information | 0x06 | Write configuration |
  | Request Spectra | 0x09 | Trigger spectrum acquisition |
  | Set Trigger Mode | 0x0A | Set triggering mode |
  """

  alias Nanodrop.Device
  alias Nanodrop.Spectrum

  # commented out commands are not used

  # OOI Protocol Commands
  @cmd_initialize 0x01
  @cmd_set_integration_time 0x02
  @cmd_set_strobe_enable 0x03
  # @cmd_set_shutdown_mode 0x04
  @cmd_query_info 0x05
  # @cmd_write_info 0x06
  @cmd_request_spectra 0x09
  @cmd_set_trigger_mode 0x0A

  # Query information slots
  @query_serial_number 0x00
  @query_wavelength_coeff_0 0x01
  @query_wavelength_coeff_1 0x02
  @query_wavelength_coeff_2 0x03
  @query_wavelength_coeff_3 0x04
  # @query_stray_light 0x05
  # @query_nonlinearity_coeff 0x06
  @query_config 0x0F

  # USB2000 specifications
  @num_pixels 2048
  # @dark_pixel_start 2
  # @dark_pixel_end 24
  @min_integration_time 3_000
  @max_integration_time 655_350_000

  @doc """
  Initializes the spectrometer.
  """
  @spec initialize(Device.t()) :: :ok | {:error, term()}
  def initialize(device) do
    Device.send_command(device, <<@cmd_initialize>>)
  end

  @doc """
  Sets the integration time in microseconds.

  Valid range: 3,000 - 655,350,000 µs
  """
  @spec set_integration_time(Device.t(), pos_integer()) :: :ok | {:error, term()}
  def set_integration_time(device, microseconds)
      when microseconds >= @min_integration_time and microseconds <= @max_integration_time do
    # Integration time is sent as milliseconds in a 16-bit value
    # The USB2000 uses a base time unit, formula varies by firmware
    # Most common: value * 1000 = microseconds, so we send ms
    ms = div(microseconds, 1000)

    Device.send_command(device, <<@cmd_set_integration_time, ms::little-16>>)
  end

  def set_integration_time(_device, microseconds) do
    {:error,
     {:invalid_integration_time, microseconds,
      min: @min_integration_time, max: @max_integration_time}}
  end

  @doc """
  Acquires a spectrum from the device.
  """
  @spec get_spectrum(Device.t()) :: {:ok, Spectrum.t()} | {:error, term()}
  def get_spectrum(device) do
    with :ok <- Device.send_command(device, <<@cmd_request_spectra>>),
         {:ok, data} <- read_spectrum_data(device) do
      {:ok, Spectrum.from_raw(data)}
    end
  end

  @doc """
  Queries device information.
  """
  @spec query_info(Device.t(), atom()) :: {:ok, term()} | {:error, term()}
  def query_info(device, :serial_number) do
    query_slot(device, @query_serial_number)
  end

  def query_info(device, :wavelength_calibration) do
    with {:ok, c0} <- query_slot(device, @query_wavelength_coeff_0),
         {:ok, c1} <- query_slot(device, @query_wavelength_coeff_1),
         {:ok, c2} <- query_slot(device, @query_wavelength_coeff_2),
         {:ok, c3} <- query_slot(device, @query_wavelength_coeff_3) do
      {:ok,
       %{
         intercept: parse_float(c0),
         first_coefficient: parse_float(c1),
         second_coefficient: parse_float(c2),
         third_coefficient: parse_float(c3)
       }}
    end
  end

  def query_info(device, :config) do
    query_slot(device, @query_config)
  end

  def query_info(_device, query_type) do
    {:error, {:unknown_query_type, query_type}}
  end

  @doc """
  Sets the trigger mode.

  Modes:
  - 0: Normal (free running)
  - 1: Software trigger
  - 2: External hardware level trigger
  - 3: External synchronization trigger
  """
  @spec set_trigger_mode(Device.t(), 0..3) :: :ok | {:error, term()}
  def set_trigger_mode(device, mode) when mode in 0..3 do
    Device.send_command(device, <<@cmd_set_trigger_mode, mode::8>>)
  end

  @doc """
  Enables or disables the strobe.
  """
  @spec set_strobe_enable(Device.t(), boolean()) :: :ok | {:error, term()}
  def set_strobe_enable(device, enabled) do
    value = if enabled, do: 1, else: 0
    Device.send_command(device, <<@cmd_set_strobe_enable, value::8>>)
  end

  # Private functions

  defp query_slot(device, slot) do
    with :ok <- Device.send_command(device, <<@cmd_query_info, slot::8>>),
         {:ok, response} <- Device.read_query(device, 64) do
      # Response format: <<command, slot, data...>> where data is null-terminated string
      case response do
        <<@cmd_query_info, ^slot, rest::binary>> ->
          {:ok, extract_string(rest)}

        _ ->
          {:error, :invalid_response}
      end
    end
  end

  defp read_spectrum_data(device) do
    # USB2000 returns spectrum as 2048 16-bit little-endian values
    # Total: 4096 bytes, but may come in multiple packets
    read_spectrum_packets(device, [], 0)
  end

  defp read_spectrum_packets(device, acc, bytes_read) when bytes_read < @num_pixels * 2 do
    case Device.read_spectrum(device, 512) do
      {:ok, data} ->
        read_spectrum_packets(device, [data | acc], bytes_read + byte_size(data))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_spectrum_packets(_device, acc, _bytes_read) do
    {:ok, IO.iodata_to_binary(Enum.reverse(acc))}
  end

  defp extract_string(binary) do
    binary
    |> :binary.split(<<0>>)
    |> List.first()
    |> String.trim()
  end

  defp parse_float(string) do
    case Float.parse(string) do
      {value, _} -> value
      :error -> 0.0
    end
  end
end
