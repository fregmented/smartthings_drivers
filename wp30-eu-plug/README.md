WP30-EU Plug Edge Driver

Target device
- LELLKI WP30-EU (power monitoring)
  - Zigbee model: TS011F
  - Manufacturer: _TZ3000_c7nc9w3c

Features
- 3x switch control (components: main, l2, l3)
- Power, energy, voltage, current measurements
- Periodic measurement polling
- Power outage behavior setting (when supported by the device)

Capabilities
- switch (x3)
- powerMeter
- energyMeter
- voltageMeasurement
- currentMeasurement
- refresh

Preferences
- logLevel: driver logging level
- powerOutageMemory: recover state after power outage (off/on/restore)
- exposeChildSwitches: create child devices for L2/L3 switch endpoints

Presentation
If the app shows the switches as disabled, apply the custom device presentation:
1) Create a VID using the SmartThings CLI:
   `smartthings presentation:device-config:create -y -i wp30-eu-plug/presentations/wp30-eu-plug.yaml -o wp30-eu-plug/presentations/wp30-eu-plug.yaml`
2) Set the `mnmn`/`vid` in `wp30-eu-plug/profiles/wp30-eu-plug.yaml`.
3) Reinstall the driver and re-add the device.

Notes
- On/Off control is sent as a Zigbee command; attribute write is used as a fallback.
- Power measurements are taken from endpoint 1.
