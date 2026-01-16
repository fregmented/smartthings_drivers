Tuya Temp/Humidity Sensor Edge Driver (Template)

Target device
- Tuya Zigbee temperature/humidity sensors (often TS0601)
- Replace the fingerprint with your device manufacturer/model

Features
- Temperature and humidity reporting
- Battery reporting (percentage)
- Refresh support
- Optional Tuya EF00 DP handling (stub)

Capabilities
- temperatureMeasurement
- relativeHumidityMeasurement
- battery
- refresh

Preferences
- logLevel: driver logging level

Presentation
If you need a custom device presentation:
1) Create a VID using the SmartThings CLI:
   `smartthings presentation:device-config:create -y -i tuya-temp-humidity-sensor/presentations/tuya-temp-humidity-sensor.yaml -o tuya-temp-humidity-sensor/presentations/tuya-temp-humidity-sensor.yaml`
2) Set the `mnmn`/`vid` in `tuya-temp-humidity-sensor/profiles/tuya-temp-humidity-sensor.yaml`.
3) Reinstall the driver and re-add the device.

Notes
- Temperature and humidity values are scaled by 0.01 in ZCL (divide by 100).
- Battery percentage remaining is reported in half-percent (divide by 2).
- Some Tuya sensors report via cluster 0xEF00 (DP reports). Add DP mapping in `tuya-temp-humidity-sensor/src/init.lua` if needed.
