# Nanodrop

[![CI](https://github.com/Vidala-Labs/nanodrop/actions/workflows/ci.yml/badge.svg)](https://github.com/Vidala-Labs/nanodrop/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/nanodrop.svg)](https://hex.pm/packages/nanodrop)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/nanodrop)
[![License](https://img.shields.io/hexpm/l/nanodrop.svg)](https://github.com/Vidala-Labs/nanodrop/blob/main/LICENSE)

Elixir library for interfacing with NanoDrop 1000 spectrophotometers over USB.

The NanoDrop 1000 internally uses an Ocean Optics USB2000 spectrometer and communicates via the OOI (Ocean Optics Interface) protocol. This library provides a clean Elixir API for spectrum acquisition, absorbance measurements, and common assays like nucleic acid and protein quantification.

## Features

- **Device Management** - Enumerate and connect to NanoDrop devices over USB
- **Spectrum Acquisition** - Raw intensity and calibrated absorbance spectra
- **Calibration** - Dark and blank reference with automatic staleness tracking
- **Assays** - Built-in nucleic acid (A260/A280) and protein (A280) measurements
- **Distributed Operation** - Control devices remotely over Erlang distribution
- **Nerves Ready** - Designed for embedded Linux deployments

## Installation

Add `nanodrop` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:nanodrop, "~> 0.1.0"}
  ]
end
```

### USB Library

This library requires [usb](https://hex.pm/packages/usb) for USB communication. It's listed as an optional dependency, so you'll need to add it explicitly on nodes that have USB access:

```elixir
def deps do
  [
    {:nanodrop, "~> 0.1.0"},
    {:usb, "~> 0.2.1"}
  ]
end
```

### Linux udev Rules

On Linux, you'll need udev rules to access the device without root. Create `/etc/udev/rules.d/99-nanodrop.rules`:

```
# NanoDrop 1000 / Ocean Optics USB2000
SUBSYSTEM=="usb", ATTR{idVendor}=="2457", ATTR{idProduct}=="1002", MODE="0666"
```

Then reload rules: `sudo udevadm control --reload-rules && sudo udevadm trigger`

## Quick Start

```elixir
# Start the server (connects to first available device)
{:ok, pid} = Nanodrop.start_link()

# Calibrate at the start of each session
:ok = Nanodrop.set_dark(pid)   # Close pedestal arm, no sample
:ok = Nanodrop.set_blank(pid)  # Water or buffer on pedestal

# Measure nucleic acid concentration
{:ok, result} = Nanodrop.measure_nucleic_acid(pid)
# => %{
#      a260: 1.5,
#      a280: 0.75,
#      a260_a280: 2.0,
#      concentration_ng_ul: 75.0,
#      spectrum: %{absorbance: [...], wavelengths: [...], ...}
#    }

# Or get the full spectrum and analyze manually
{:ok, spectrum} = Nanodrop.get_spectrum(pid)
abs_280 = Nanodrop.absorbance_at(spectrum, 280.0)
```

## Calibration

For accurate absorbance measurements, calibrate with two reference spectra:

1. **Dark** - Detector baseline with no light. Close the pedestal arm with nothing on the pedestal.
2. **Blank** - 100% transmission reference. Place your solvent (water, buffer) on the pedestal.

Absorbance is calculated as: `A = -log10((sample - dark) / (blank - dark))`

Calibration expires after 30 minutes of inactivity (no measurements for 5+ minutes). The library will return `{:error, :recalibration_needed}` when recalibration is required.

## API Reference

### Device Management

```elixir
# List connected devices
Nanodrop.list_devices()
#=> [%{vendor_id: 0x2457, product_id: 0x1002, bus: 1, address: 19, device_ref: #Ref<...>}]

# Start with a specific device
{:ok, pid} = Nanodrop.start_link(device: device_info)

# Get device info
Nanodrop.info(pid)
Nanodrop.serial_number(pid)
Nanodrop.wavelength_calibration(pid)
```

### Configuration

```elixir
# Set integration time (3,000 - 655,350,000 microseconds)
Nanodrop.set_integration_time(pid, 100_000)  # 100ms

# Check calibration status
Nanodrop.calibrated?(pid)  #=> true | false
```

### Spectrum Acquisition

```elixir
# Raw spectrum (no calibration required)
{:ok, spectrum} = Nanodrop.get_raw_spectrum(pid)

# Absorbance spectrum (requires calibration)
{:ok, spectrum} = Nanodrop.get_spectrum(pid)

# Get absorbance at specific wavelength
Nanodrop.absorbance_at(spectrum, 260.0)
```

### Assays

```elixir
# Nucleic acid quantification
{:ok, result} = Nanodrop.measure_nucleic_acid(pid)
{:ok, result} = Nanodrop.measure_nucleic_acid(pid, factor: 40.0)  # RNA

# Protein quantification
{:ok, result} = Nanodrop.measure_protein(pid)
{:ok, result} = Nanodrop.measure_protein(pid, extinction_coefficient: 1.4)
```

## Distributed Operation

This library is designed for distributed Erlang deployments. Run the NanoDrop server on a node with USB access and control it from anywhere in the cluster.

### Direct Node Reference

```elixir
# On the device node (e.g., nanodrop@device.local)
{:ok, pid} = Nanodrop.start_link(name: Nanodrop)

# From a remote node
Nanodrop.set_dark({Nanodrop, :"nanodrop@device.local"})
Nanodrop.set_blank({Nanodrop, :"nanodrop@device.local"})
{:ok, result} = Nanodrop.measure_nucleic_acid({Nanodrop, :"nanodrop@device.local"})
```

### Global Registration

```elixir
# On the device node
{:ok, pid} = Nanodrop.start_link(name: {:global, :nanodrop})

# From any connected node
Nanodrop.set_dark({:global, :nanodrop})
{:ok, result} = Nanodrop.measure_nucleic_acid({:global, :nanodrop})
```

### Process Groups

```elixir
# On the device node
{:ok, pid} = Nanodrop.start_link()
:pg.join(:spectrophotometers, pid)

# From any connected node
[pid | _] = :pg.get_members(:spectrophotometers)
{:ok, result} = Nanodrop.measure_nucleic_acid(pid)
```

### Network-Only Mode

On nodes without USB access, configure network-only mode to skip device initialization:

```elixir
# config/config.exs
config :nanodrop, network_only: true
```

This causes `Nanodrop.start_link/1` to return `:ignore`, allowing the application to start without USB hardware.

## Hardware

### Supported Devices

| Device | USB VID | USB PID | Status |
|--------|---------|---------|--------|
| NanoDrop 1000 | 0x2457 | 0x1002 | Supported |
| Ocean Optics USB2000 | 0x2457 | 0x1002 | Should work |

### Specifications

- **Wavelength Range**: 220-750 nm (full UV-Vis spectrum)
- **Detector**: 2048-pixel linear CCD array
- **Path Lengths**: 1mm and 0.2mm
- **Sample Volume**: 1 µL
- **Light Source**: Pulsed xenon flash lamp

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

- Protocol documentation from [python-seabreeze](https://github.com/ap--/python-seabreeze)
- USB library by the [usb](https://hex.pm/packages/usb) maintainers
