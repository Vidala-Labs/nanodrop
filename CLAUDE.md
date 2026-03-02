# NanoDrop Elixir Library

An Elixir/Nerves library for interfacing with NanoDrop 1000 spectrophotometers over USB.

## Project Status

**Protocol Confirmed** - NanoDrop 1000 uses standard Ocean Optics USB2000 protocol.

## Hardware Overview

### NanoDrop 1000 Specifications
- Full-spectrum UV-Vis spectrophotometer (220-750 nm)
- Measures 1 µl samples with high accuracy
- Uses fiber optic cables for sample measurement (1mm and 0.2mm path lengths)
- Pulsed xenon flash lamp light source
- Linear CCD array spectrometer detector (2048 pixels)
- USB connection to PC

### Confirmed USB Identity
```
Bus 001 Device 019: ID 2457:1002 Ocean Optics Inc. Ocean Optics USB2000
iManufacturer: USB2000 2.41.3 ND2
iProduct:      Ocean Optics USB2000
```

- **USB Vendor ID**: `0x2457` (Ocean Optics)
- **USB Product ID**: `0x1002` (USB2000)
- **Firmware Version**: 2.41.3 ND2 (NanoDrop variant)
- **Microcontroller**: Cypress/Anchor EZ-USB
- **Power**: Bus powered, 400mA max

## Protocol Information

### Ocean Optics OOI Protocol
The protocol is **NOT encrypted** - it uses simple USB bulk transfers.

#### Confirmed USB Endpoints (from device)
| Endpoint | Type | Size | Address | Purpose |
|----------|------|------|---------|---------|
| EP2 Out  | Bulk | 64 bytes | 0x02 | Commands |
| EP2 In   | Bulk | 64 bytes | 0x82 | Spectrum data |
| EP7 Out  | Bulk | 64 bytes | 0x07 | Secondary commands |
| EP7 In   | Bulk | 64 bytes | 0x87 | Query responses |

#### python-seabreeze USB2000 config (for reference)
```python
usb_product_id = 0x1002
usb_endpoint_map = EndPointMap(
    ep_out=0x02,        # Commands
    lowspeed_in=0x87,   # Query responses
    highspeed_in=0x82   # Spectrum data
)
```

#### Command Set
Commands are sent as bulk transfers to the OUT endpoint:

| Command | Hex | Description |
|---------|-----|-------------|
| Initialize | 0x01 | Initialize spectrometer |
| Set Integration Time | 0x02 | Set integration time in µs |
| Set Strobe Enable | 0x03 | Enable/disable strobe |
| Set Shutdown Mode | 0x04 | Enter low-power mode |
| Query Information | 0x05 | Query device info/calibration |
| Write Information | 0x06 | Write configuration |
| Request Spectra | 0x09 | Trigger spectrum acquisition |
| Set Trigger Mode | 0x0A | Set triggering mode |

#### Trigger Modes
- 0: Normal (free running)
- 1: Software trigger
- 2: External hardware level trigger
- 3: External synchronization trigger
- 4: External hardware edge trigger

#### Spectrum Data
- USB2000/USB2000+: 2048 pixels
- Data returned via bulk transfer on high-speed IN endpoint (0x82)
- Dark pixel ranges vary by model (USB2000: pixels 2-24, USB2000+: pixels 6-21)

## Elixir Implementation Strategy

### USB Library Options

1. **usb (hex.pm)** - Erlang USB interface, NIF binding to libusb
   - Works on Linux and macOS
   - https://hex.pm/packages/usb

2. **elixir-libusb** - LibUSB wrapper for Elixir by ConnorRigby
   - Provides `LibUSB.Nif.get_device_list()`, `LibUSB.Nif.open()`, `LibUSB.Nif.bulk_transfer()`
   - https://github.com/ConnorRigby/elixir-libusb

### Nerves Considerations
- Target platform: Nerves (embedded Linux)
- Need libusb installed on target system
- May need custom udev rules for device permissions
- Consider using NIFs for USB communication (synchronous operations)

### Architecture
```
┌─────────────────────────────────────────┐
│             Application                  │
├─────────────────────────────────────────┤
│          NanoDrop API                   │
│  (measure/0, get_spectrum/0, etc.)      │
├─────────────────────────────────────────┤
│         Protocol Layer                   │
│  (OOI Protocol implementation)          │
├─────────────────────────────────────────┤
│          USB Transport                   │
│  (libusb NIF wrapper)                   │
├─────────────────────────────────────────┤
│          libusb / Linux USB             │
└─────────────────────────────────────────┘
```

## Reference Implementations

### Python (most complete)
- **python-seabreeze**: https://github.com/ap--/python-seabreeze
  - pyseabreeze backend implements OOI protocol in pure Python
  - Source: `seabreeze/pyseabreeze/protocol.py`, `seabreeze/pyseabreeze/devices.py`
  - Documentation: https://python-seabreeze.readthedocs.io/

### C/C++
- **SeaBreeze**: https://sourceforge.net/projects/seabreeze/
  - Official Ocean Optics library
  - Reference implementation of USB protocol

### Firmware Tools
- **cypress-anchor-ez-usb-eeprom-dumper**: https://github.com/Juul/cypress-anchor-ez-usb-eeprom-dumper
  - Tools for NanoDrop/Ocean Optics firmware
  - Useful for understanding low-level device operation

## Reverse Engineering Strategy

If NanoDrop uses a different/modified protocol:

1. **Windows VM Setup**
   - Install NanoDrop 1000 software (V3.8.1)
   - Pass USB device through to VM
   - Required: LVRuntime7, NI-VISA 4.4.1, NanoDrop drivers

2. **USB Traffic Capture**
   - Use Wireshark with USBPcap on Windows
   - Or usbmon on Linux
   - Capture traffic during: initialization, measurement, calibration

3. **Protocol Analysis**
   - Compare captured traffic to known OOI protocol
   - Identify command sequences and response formats
   - Document any NanoDrop-specific extensions

## Key Questions to Resolve

- [x] Confirm NanoDrop 1000 USB VID:PID → **0x2457:0x1002 (USB2000)**
- [x] Verify if NanoDrop uses standard OOI protocol → **Yes, standard USB2000 protocol**
- [x] Determine if calibration data is stored on device or in software → **Stored on device EEPROM**
- [x] Test basic communication with OOI protocol commands → **Working**
- [x] Verify spectrum acquisition works with standard commands → **Working (2048 pixels)**

## Resources

### Official Documentation
- NanoDrop 1000 User Manual: https://documents.thermofisher.com/TFS-Assets/CAD/manuals/nd-1000-v3.8-users-manual-8%205x11.pdf
- USB2000+ OEM Data Sheet: https://spectrecology.com/wp-content/uploads/2020/11/USB2000-Data-Sheet.pdf

### Community Resources
- USB ID Database (VID 0x2457): https://the-sz.com/products/usbid/?v=0x2457
- Ocean Optics udev rules: https://github.com/ap--/python-seabreeze/blob/main/os_support/10-oceanoptics.rules

### Windows Installation (for reverse engineering)
Registry fix for Windows 10:
```
HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\usbflags\245710020002
"SkipBOSDescriptorQuery"=dword:00000001
```
