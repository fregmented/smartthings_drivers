WP30-EU Plug Edge Driver Template

What to customize
- driver.yaml: update name, packageKey, vendorSupportInformation, and version.
- fingerprints.yml: replace TODO_MANUFACTURER and model if needed.
- profiles/wp30-eu-plug.yaml: adjust capabilities if the device supports more/less.
- src/init.lua: add cluster handlers or lifecycle logic for non-standard behavior.

Notes
- This template assumes a Zigbee plug with switch, power meter, and energy meter.
- If the device is not Zigbee, update permissions and use the correct SmartThings driver libraries.
