local capabilities = require "st.capabilities"
local device_management = require "st.zigbee.device_management"
local log = require "log"
local zigbee_driver = require "st.zigbee"
local zcl_clusters = require "st.zigbee.zcl.clusters"

local TUYA_EF00_CLUSTER_ID = 0xEF00
local BATTERY_VOLTAGE_MIN_MV = 1500
local BATTERY_VOLTAGE_MAX_MV = 2800
local LAST_BATTERY_VOLTAGE_FIELD = "last_battery_voltage_mv"

local LOG_LEVEL_ORDER = {
  ERROR = 1,
  WARN = 2,
  INFO = 3,
  DEBUG = 4,
}

local function normalize_log_level(level)
  if type(level) ~= "string" then
    return "INFO"
  end
  level = string.upper(level)
  if LOG_LEVEL_ORDER[level] then
    return level
  end
  return "INFO"
end

local function should_log(device, level)
  local current = "INFO"
  if device and device.preferences and device.preferences.logLevel then
    current = normalize_log_level(device.preferences.logLevel)
  end
  return LOG_LEVEL_ORDER[level] <= LOG_LEVEL_ORDER[current]
end

local function log_debug(device, message)
  if should_log(device, "DEBUG") then
    log.debug(message)
  end
end

local function log_info(device, message)
  if should_log(device, "INFO") then
    log.info(message)
  end
end

local function log_value_change(device, label, previous, current)
  if previous == nil or previous ~= current then
    log_info(device, string.format("%s changed: %s -> %s", label, tostring(previous), tostring(current)))
  end
end

local function send_with_log(device, zb_tx, label)
  if not zb_tx then
    return
  end
  if label then
    log_debug(device, string.format("Zigbee TX %s: %s", label, tostring(zb_tx)))
  else
    log_debug(device, string.format("Zigbee TX: %s", tostring(zb_tx)))
  end
  device:send(zb_tx)
end

local function battery_voltage_to_percent(voltage_mv)
  if not voltage_mv then
    return nil
  end
  local percent = math.floor((((voltage_mv - BATTERY_VOLTAGE_MIN_MV) / (BATTERY_VOLTAGE_MAX_MV - BATTERY_VOLTAGE_MIN_MV)) * 100) + 0.5)
  if percent < 0 then
    percent = 0
  elseif percent > 100 then
    percent = 100
  end
  return percent
end

local function apply_log_level(device)
  if not device or not device.preferences then
    return
  end
  local level = normalize_log_level(device.preferences.logLevel)
  local log_level = log[level]
  if log.set_level and log_level then
    pcall(log.set_level, log_level)
  elseif log.set_level then
    pcall(log.set_level, level)
  end
end

local function temperature_attr_handler(_, device, value, zb_rx)
  local celsius = value.value / 100
  log_debug(device, string.format("Zigbee RX Temperature: %s", tostring(zb_rx)))
  local previous = device:get_latest_state("main", capabilities.temperatureMeasurement.ID, capabilities.temperatureMeasurement.temperature.NAME)
  log_value_change(device, "Temperature", previous, celsius)
  device:emit_event(capabilities.temperatureMeasurement.temperature({ value = celsius, unit = "C" }))
end

local function humidity_attr_handler(_, device, value, zb_rx)
  local humidity = value.value / 100
  log_debug(device, string.format("Zigbee RX Humidity: %s", tostring(zb_rx)))
  local previous = device:get_latest_state("main", capabilities.relativeHumidityMeasurement.ID, capabilities.relativeHumidityMeasurement.humidity.NAME)
  log_value_change(device, "Humidity", previous, humidity)
  device:emit_event(capabilities.relativeHumidityMeasurement.humidity(humidity))
end

local function battery_voltage_attr_handler(_, device, value, zb_rx)
  local voltage_mv = value.value * 100
  log_debug(device, string.format("Zigbee RX Battery Voltage: %s", tostring(zb_rx)))
  device:set_field(LAST_BATTERY_VOLTAGE_FIELD, voltage_mv, { persist = false })
  local percent = battery_voltage_to_percent(voltage_mv)
  if percent ~= nil then
    local previous = device:get_latest_state("main", capabilities.battery.ID, capabilities.battery.battery.NAME)
    log_value_change(device, "Battery", previous, percent)
    device:emit_event(capabilities.battery.battery(percent))
  end
end

local function battery_percentage_attr_handler(_, device, value, zb_rx)
  if device:get_field(LAST_BATTERY_VOLTAGE_FIELD) then
    log_debug(device, string.format("Zigbee RX Battery Percentage (ignored, voltage preferred): %s", tostring(zb_rx)))
    return
  end
  local percent = math.floor((value.value / 2) + 0.5)
  if percent < 0 then
    percent = 0
  elseif percent > 100 then
    percent = 100
  end
  log_debug(device, string.format("Zigbee RX Battery: %s", tostring(zb_rx)))
  local previous = device:get_latest_state("main", capabilities.battery.ID, capabilities.battery.battery.NAME)
  log_value_change(device, "Battery", previous, percent)
  device:emit_event(capabilities.battery.battery(percent))
end

local function tuya_cluster_handler(_, device, zb_rx)
  -- TODO: Add datapoint parsing for EF00 reports if the device uses Tuya DP payloads.
  log_debug(device, string.format("Tuya EF00 message received: %s", tostring(zb_rx)))
end

local function refresh_handler(_, device)
  log_debug(device, "Refresh command received")
  send_with_log(device, zcl_clusters.TemperatureMeasurement.attributes.MeasuredValue:read(device), "Read Temperature")
  send_with_log(device, zcl_clusters.RelativeHumidity.attributes.MeasuredValue:read(device), "Read Humidity")
  send_with_log(device, zcl_clusters.PowerConfiguration.attributes.BatteryVoltage:read(device), "Read Battery Voltage")
  send_with_log(device, zcl_clusters.PowerConfiguration.attributes.BatteryPercentageRemaining:read(device), "Read Battery Percentage")
end

local function device_added(_, device)
  apply_log_level(device)
  refresh_handler(nil, device)
end

local function device_init(_, device)
  apply_log_level(device)
end

local function do_configure(_, device)
  log_debug(device, "Configure requested")
  local hub_eui = device.hub_zigbee_eui
  if hub_eui then
    send_with_log(device, device_management.build_bind_request(device, zcl_clusters.TemperatureMeasurement.ID, hub_eui), "Bind Temperature")
    send_with_log(device, device_management.build_bind_request(device, zcl_clusters.RelativeHumidity.ID, hub_eui), "Bind Humidity")
    send_with_log(device, device_management.build_bind_request(device, zcl_clusters.PowerConfiguration.ID, hub_eui), "Bind PowerConfiguration")
  end

  send_with_log(device, zcl_clusters.TemperatureMeasurement.attributes.MeasuredValue:configure_reporting(device, 30, 300, 50), "Configure Temperature Reporting")
  send_with_log(device, zcl_clusters.RelativeHumidity.attributes.MeasuredValue:configure_reporting(device, 30, 300, 100), "Configure Humidity Reporting")
  send_with_log(device, zcl_clusters.PowerConfiguration.attributes.BatteryVoltage:configure_reporting(device, 3600, 21600, 1), "Configure Battery Voltage Reporting")
  send_with_log(device, zcl_clusters.PowerConfiguration.attributes.BatteryPercentageRemaining:configure_reporting(device, 3600, 21600, 1), "Configure Battery Percentage Reporting")

  refresh_handler(nil, device)
end

local function info_changed(_, device)
  apply_log_level(device)
  local level = normalize_log_level(device.preferences and device.preferences.logLevel)
  log_info(device, "Log level set to " .. level)
end

local driver = zigbee_driver("tuya-temp-humidity-sensor", {
  supported_capabilities = {
    capabilities.temperatureMeasurement,
    capabilities.relativeHumidityMeasurement,
    capabilities.battery,
    capabilities.refresh,
  },
  zigbee_handlers = {
    attr = {
      [zcl_clusters.TemperatureMeasurement.ID] = {
        [zcl_clusters.TemperatureMeasurement.attributes.MeasuredValue.ID] = temperature_attr_handler,
      },
      [zcl_clusters.RelativeHumidity.ID] = {
        [zcl_clusters.RelativeHumidity.attributes.MeasuredValue.ID] = humidity_attr_handler,
      },
      [zcl_clusters.PowerConfiguration.ID] = {
        [zcl_clusters.PowerConfiguration.attributes.BatteryVoltage.ID] = battery_voltage_attr_handler,
        [zcl_clusters.PowerConfiguration.attributes.BatteryPercentageRemaining.ID] = battery_percentage_attr_handler,
      },
    },
    cluster = {
      [TUYA_EF00_CLUSTER_ID] = {
        [0x01] = tuya_cluster_handler,
        [0x02] = tuya_cluster_handler,
      },
    },
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      refresh = refresh_handler,
    },
  },
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    doConfigure = do_configure,
    infoChanged = info_changed,
  },
})

driver:run()
