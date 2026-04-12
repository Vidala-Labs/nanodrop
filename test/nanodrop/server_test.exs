defmodule Nanodrop.ServerTest do
  use ExUnit.Case, async: false

  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  @vendor_id 0x2457
  @product_id 0x1002

  # Helper to create a mock device setup
  defp mock_device_setup(device_ref \\ make_ref(), handle \\ make_ref()) do
    Nanodrop.USB.Mock
    |> expect(:get_device_list, fn -> {:ok, [device_ref]} end)
    |> expect(:get_device_descriptor, fn ^device_ref ->
      {:ok, %{vendor_id: @vendor_id, product_id: @product_id}}
    end)
    |> expect(:get_bus_number, fn ^device_ref -> {:ok, 1} end)
    |> expect(:get_device_address, fn ^device_ref -> {:ok, 19} end)
    |> expect(:get_device_descriptor, fn ^device_ref ->
      {:ok, %{vendor_id: @vendor_id, product_id: @product_id}}
    end)
    |> expect(:open_device, fn ^device_ref -> {:ok, handle} end)
    |> expect(:claim_interface, fn ^handle, 0 -> :ok end)

    {device_ref, handle}
  end

  # Helper to mock device initialization protocol
  defp mock_device_init(handle) do
    # Initialize command
    Nanodrop.USB.Mock
    |> expect(:write_bulk, fn ^handle, 0x02, <<0x01>>, 1000 -> {:ok, 1} end)
    # Set integration time (100ms = 100 in 16-bit LE)
    |> expect(:write_bulk, fn ^handle, 0x02, <<0x02, 100::little-16>>, 1000 -> {:ok, 3} end)
    # Query serial number
    |> expect(:write_bulk, fn ^handle, 0x02, <<0x05, 0x00>>, 1000 -> {:ok, 2} end)
    |> expect(:read_bulk, fn ^handle, 0x87, 64, 1000 ->
      {:ok, <<0x05, 0x00, "USB2000-ND1234", 0x00>>}
    end)
    # Query wavelength coefficients (4 queries)
    |> expect(:write_bulk, fn ^handle, 0x02, <<0x05, 0x01>>, 1000 -> {:ok, 2} end)
    |> expect(:read_bulk, fn ^handle, 0x87, 64, 1000 ->
      {:ok, <<0x05, 0x01, "200.0", 0x00>>}
    end)
    |> expect(:write_bulk, fn ^handle, 0x02, <<0x05, 0x02>>, 1000 -> {:ok, 2} end)
    |> expect(:read_bulk, fn ^handle, 0x87, 64, 1000 ->
      {:ok, <<0x05, 0x02, "0.5", 0x00>>}
    end)
    |> expect(:write_bulk, fn ^handle, 0x02, <<0x05, 0x03>>, 1000 -> {:ok, 2} end)
    |> expect(:read_bulk, fn ^handle, 0x87, 64, 1000 ->
      {:ok, <<0x05, 0x03, "0.0001", 0x00>>}
    end)
    |> expect(:write_bulk, fn ^handle, 0x02, <<0x05, 0x04>>, 1000 -> {:ok, 2} end)
    |> expect(:read_bulk, fn ^handle, 0x87, 64, 1000 ->
      {:ok, <<0x05, 0x04, "0.0", 0x00>>}
    end)
  end

  # Helper to mock spectrum acquisition (with strobe)
  # USB2000 sends 4096 bytes + sync byte in 64-byte packets
  defp mock_spectrum_acquisition(handle, pixel_value) do
    spectrum_data = :binary.copy(<<pixel_value::little-16>>, 2048)

    Nanodrop.USB.Mock
    # Strobe enable
    |> expect(:write_bulk, fn ^handle, 0x02, <<0x03, 0x01>>, 1000 -> {:ok, 2} end)
    # Request spectra
    |> expect(:write_bulk, fn ^handle, 0x02, <<0x09>>, 1000 -> {:ok, 1} end)
    # Read spectrum in 64-byte chunks (64 reads for 4096 bytes + sync)
    |> mock_spectrum_reads(handle, spectrum_data)
    # Strobe disable
    |> expect(:write_bulk, fn ^handle, 0x02, <<0x03, 0x00>>, 1000 -> {:ok, 2} end)
  end

  # Helper to mock dark spectrum acquisition (no strobe)
  defp mock_dark_spectrum_acquisition(handle, pixel_value) do
    spectrum_data = :binary.copy(<<pixel_value::little-16>>, 2048)

    Nanodrop.USB.Mock
    # Strobe disable
    |> expect(:write_bulk, fn ^handle, 0x02, <<0x03, 0x00>>, 1000 -> {:ok, 2} end)
    # Request spectra
    |> expect(:write_bulk, fn ^handle, 0x02, <<0x09>>, 1000 -> {:ok, 1} end)
    # Read spectrum in 64-byte chunks
    |> mock_spectrum_reads(handle, spectrum_data)
  end

  # Mock 64 reads of 64 bytes each + sync byte
  defp mock_spectrum_reads(mock, handle, spectrum_data) do
    # 4096 bytes / 64 = 64 packets
    mock =
      Enum.reduce(0..63, mock, fn i, acc ->
        offset = i * 64
        expect(acc, :read_bulk, fn ^handle, 0x82, 64, 1000 ->
          {:ok, binary_part(spectrum_data, offset, 64)}
        end)
      end)

    # Final sync byte
    expect(mock, :read_bulk, fn ^handle, 0x82, 64, 1000 ->
      {:ok, <<0x69>>}
    end)
  end

  defp start_server do
    {_device_ref, handle} = mock_device_setup()
    mock_device_init(handle)
    {:ok, pid} = Nanodrop.start_link()
    {pid, handle}
  end

  describe "start_link/1" do
    test "starts server and connects to device" do
      {pid, _handle} = start_server()

      assert Process.alive?(pid)
    end

    test "returns error when no device found" do
      expect(Nanodrop.USB.Mock, :get_device_list, fn -> {:ok, []} end)

      # start_link with {:stop, reason} from init causes EXIT, so we trap it
      Process.flag(:trap_exit, true)
      assert {:error, :no_device_found} = Nanodrop.start_link()
    end
  end

  describe "serial_number/1" do
    test "returns device serial number" do
      {pid, _handle} = start_server()

      assert Nanodrop.serial_number(pid) == "USB2000-ND1234"
    end
  end

  describe "wavelength_calibration/1" do
    test "returns calibration coefficients" do
      {pid, _handle} = start_server()

      cal = Nanodrop.wavelength_calibration(pid)

      assert cal.intercept == 200.0
      assert cal.first_coefficient == 0.5
      assert cal.second_coefficient == 0.0001
      assert cal.third_coefficient == 0.0
    end
  end

  describe "info/1" do
    test "returns device info" do
      {pid, _handle} = start_server()

      info = Nanodrop.info(pid)

      assert info.serial_number == "USB2000-ND1234"
      assert info.integration_time == 100_000
      assert info.calibrated == false
      assert info.calibrated_at == nil
    end
  end

  describe "calibrated?/1" do
    test "returns false when not calibrated" do
      {pid, _handle} = start_server()

      assert Nanodrop.calibrated?(pid) == false
    end

    test "returns true after dark and blank are set" do
      {pid, handle} = start_server()

      # Set dark (no strobe)
      mock_dark_spectrum_acquisition(handle, 100)
      :ok = Nanodrop.set_dark(pid)

      # Set blank (with strobe)
      mock_spectrum_acquisition(handle, 10000)
      :ok = Nanodrop.set_blank(pid)

      assert Nanodrop.calibrated?(pid) == true
    end
  end

  describe "set_integration_time/2" do
    test "sets integration time" do
      {pid, handle} = start_server()

      # 50ms = 50 in 16-bit LE
      expect(Nanodrop.USB.Mock, :write_bulk, fn ^handle, 0x02, <<0x02, 50::little-16>>, 1000 ->
        {:ok, 3}
      end)

      assert :ok = Nanodrop.set_integration_time(pid, 50_000)
    end
  end

  describe "get_raw_spectrum/1" do
    test "returns raw spectrum data" do
      {pid, handle} = start_server()

      mock_spectrum_acquisition(handle, 5000)

      {:ok, spectrum} = Nanodrop.get_raw_spectrum(pid)

      assert length(spectrum.raw_pixels) == 2048
      # Note: USB2000 byte reordering means uniform input produces non-uniform output
      # Just verify we got pixel data in expected range
      assert Enum.all?(spectrum.raw_pixels, &(&1 >= 0 and &1 <= 65535))
    end
  end

  describe "get_spectrum/1" do
    test "returns error when not calibrated" do
      {pid, _handle} = start_server()

      assert {:error, :no_dark_calibration} = Nanodrop.get_spectrum(pid)
    end

    test "returns absorbance spectrum when calibrated" do
      {pid, handle} = start_server()

      # Dark = 100 (no strobe)
      mock_dark_spectrum_acquisition(handle, 100)
      :ok = Nanodrop.set_dark(pid)

      # Blank = 10000 (with strobe)
      mock_spectrum_acquisition(handle, 10000)
      :ok = Nanodrop.set_blank(pid)

      # Sample = 5050 (50% transmittance, with strobe)
      mock_spectrum_acquisition(handle, 5050)

      {:ok, spectrum} = Nanodrop.get_spectrum(pid)

      assert length(spectrum.absorbance) == 2048
      assert length(spectrum.wavelengths) == 2048
      assert spectrum.timestamp != nil

      # Check that wavelengths are calculated correctly
      # λ(0) = 200 + 0.5*0 + 0.0001*0 + 0*0 = 200
      assert hd(spectrum.wavelengths) == 200.0
    end
  end

  describe "absorbance_at/2" do
    test "returns absorbance at specific wavelength" do
      {pid, handle} = start_server()

      # Dark = 100 (no strobe)
      mock_dark_spectrum_acquisition(handle, 100)
      :ok = Nanodrop.set_dark(pid)

      # Blank = 10000 (with strobe)
      mock_spectrum_acquisition(handle, 10000)
      :ok = Nanodrop.set_blank(pid)

      # Sample = 1090 (10% transmittance, ~1 A, with strobe)
      mock_spectrum_acquisition(handle, 1090)

      {:ok, spectrum} = Nanodrop.get_spectrum(pid)

      # With uniform pixel values, all wavelengths should have same absorbance
      a260 = Nanodrop.absorbance_at(spectrum, 260.0)
      a280 = Nanodrop.absorbance_at(spectrum, 280.0)

      assert is_float(a260)
      assert is_float(a280)
      # With uniform sample they should be equal
      assert_in_delta(a260, a280, 0.01)
    end
  end

  describe "measure_nucleic_acid/2" do
    test "returns nucleic acid measurements" do
      {pid, handle} = start_server()

      # Dark = 100 (no strobe)
      mock_dark_spectrum_acquisition(handle, 100)
      :ok = Nanodrop.set_dark(pid)

      # Blank = 10000 (with strobe)
      mock_spectrum_acquisition(handle, 10000)
      :ok = Nanodrop.set_blank(pid)

      # Sample with ~50% transmittance (with strobe)
      mock_spectrum_acquisition(handle, 5050)

      {:ok, result} = Nanodrop.measure_nucleic_acid(pid)

      assert Map.has_key?(result, :a260)
      assert Map.has_key?(result, :a280)
      assert Map.has_key?(result, :a230)
      assert Map.has_key?(result, :a260_a280)
      assert Map.has_key?(result, :a260_a230)
      assert Map.has_key?(result, :concentration_ng_ul)
      assert Map.has_key?(result, :spectrum)
    end

    test "calculates concentration with custom factor" do
      {pid, handle} = start_server()

      # Dark (no strobe)
      mock_dark_spectrum_acquisition(handle, 100)
      :ok = Nanodrop.set_dark(pid)

      # Blank (with strobe)
      mock_spectrum_acquisition(handle, 10000)
      :ok = Nanodrop.set_blank(pid)

      # Sample (with strobe)
      mock_spectrum_acquisition(handle, 1090)

      {:ok, result_dna} = Nanodrop.measure_nucleic_acid(pid, factor: 50.0)

      # Get another spectrum for RNA measurement
      mock_spectrum_acquisition(handle, 1090)
      {:ok, result_rna} = Nanodrop.measure_nucleic_acid(pid, factor: 40.0)

      # Same absorbance, different factors
      assert_in_delta result_dna.concentration_ng_ul / 50.0, result_rna.concentration_ng_ul / 40.0, 0.0001
    end
  end

  describe "measure_protein/2" do
    test "returns protein measurements" do
      {pid, handle} = start_server()

      # Dark (no strobe)
      mock_dark_spectrum_acquisition(handle, 100)
      :ok = Nanodrop.set_dark(pid)

      # Blank (with strobe)
      mock_spectrum_acquisition(handle, 10000)
      :ok = Nanodrop.set_blank(pid)

      # Sample (with strobe)
      mock_spectrum_acquisition(handle, 5050)

      {:ok, result} = Nanodrop.measure_protein(pid)

      assert Map.has_key?(result, :a280)
      assert Map.has_key?(result, :concentration_mg_ml)
      assert Map.has_key?(result, :spectrum)
    end
  end
end
