local capabilities = require "st.capabilities"
local log = require "log"
local zigbee_driver = require "st.zigbee"
local zcl_clusters = require "st.zigbee.zcl.clusters"
local device_management = require "st.zigbee.device_management"
local data_types = require "st.zigbee.data_types"
local zcl_messages = require "st.zigbee.zcl"
local read_attribute = require "st.zigbee.zcl.global_commands.read_attribute"
local write_attribute = require "st.zigbee.zcl.global_commands.write_attribute"
local messages = require "st.zigbee.messages"
local zb_const = require "st.zigbee.constants"

require "overridden"

local DRIVER_VERSION = "0.0.2"

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

local function format_zcl_body(message)
  if type(message) == "table" and message.body and message.body.zcl_body then
    return tostring(message.body.zcl_body)
  end
  if type(message) == "table" and message.zcl_body then
    return tostring(message.zcl_body)
  end
  return tostring(message)
end

local function event_to_string(event)
  if type(event) ~= "table" then
    return tostring(event)
  end
  local capability = event.capability
  if type(capability) == "table" then
    capability = capability.ID or capability.id or capability.name
  end
  local attribute = event.attribute or event.attribute_name
  local value = event.value
  local unit = event.unit
  local value_str = tostring(value)
  if unit then
    value_str = value_str .. " " .. tostring(unit)
  end
  if capability and attribute then
    return string.format("%s.%s=%s", capability, attribute, value_str)
  end
  if attribute then
    return string.format("%s=%s", attribute, value_str)
  end
  return value_str
end

local function values_equal(a, b)
  if a == b then
    return true
  end
  if a == nil or b == nil then
    return false
  end
  return tostring(a) == tostring(b)
end

local function log_value_change(device, component_id, event)
  if not event then
    return
  end
  local capability = event.capability
  if type(capability) == "table" then
    capability = capability.ID or capability.id or capability.name
  end
  local attribute = event.attribute or event.attribute_name
  local previous = nil
  if capability and attribute and device.get_latest_state then
    local ok, state = pcall(device.get_latest_state, device, component_id, capability, attribute)
    if ok then
      previous = state
    end
  end
  if not values_equal(previous, event.value) then
    log_info(device, string.format("Value changed on %s: %s (was %s)", component_id, event_to_string(event), tostring(previous)))
  end
end

local CHILD_SWITCH_PREF = "exposeChildSwitches"
local CHILD_SWITCH_PROFILE = "wp30-eu-plug-child-switch"
local CHILD_SWITCH_ENDPOINTS = { 2, 3 }

local function is_child_device(device)
  return device and device.parent_assigned_child_key ~= nil
end

local function child_key_for_endpoint(endpoint)
  return string.format("%02X", endpoint)
end

local function get_child_device(device, endpoint)
  if not device or not device.get_child_by_parent_assigned_key then
    return nil
  end
  return device:get_child_by_parent_assigned_key(child_key_for_endpoint(endpoint))
end

local function should_create_child_devices(device)
  return device and device.preferences and device.preferences[CHILD_SWITCH_PREF] == true
end

local function create_child_devices(driver, device)
  if not driver or not device or is_child_device(device) then
    return
  end
  if not should_create_child_devices(device) then
    return
  end
  if not device.get_child_by_parent_assigned_key then
    log_info(device, "Child devices require firmware 45.1+")
    return
  end
  local base_label = device.label or "WP30-EU Plug"
  for _, endpoint in ipairs(CHILD_SWITCH_ENDPOINTS) do
    local child_key = child_key_for_endpoint(endpoint)
    local existing = device:get_child_by_parent_assigned_key(child_key)
    if not existing then
      local suffix = endpoint == 2 and "L2" or "L3"
      local label = string.format("%s %s", base_label, suffix)
      driver:try_create_device({
        type = "EDGE_CHILD",
        device_network_id = nil,
        parent_assigned_child_key = child_key,
        label = label,
        profile = CHILD_SWITCH_PROFILE,
        parent_device_id = device.id,
        manufacturer = driver.NAME,
        model = CHILD_SWITCH_PROFILE,
        vendor_provided_label = label,
      })
    end
  end
end

local COMPONENT_TO_ENDPOINT = {
  main = 1,
  l2 = 2,
  l3 = 3,
}

local ENDPOINT_TO_COMPONENT = {
  [1] = "main",
  [2] = "l2",
  [3] = "l3",
}

local FIELD_KEYS = {
  ac_current_multiplier = "ac_current_multiplier",
  ac_current_divisor = "ac_current_divisor",
  ac_voltage_multiplier = "ac_voltage_multiplier",
  ac_voltage_divisor = "ac_voltage_divisor",
  ac_power_multiplier = "ac_power_multiplier",
  ac_power_divisor = "ac_power_divisor",
  metering_multiplier = "metering_multiplier",
  metering_divisor = "metering_divisor",
}

local DEFAULTS = {
  ac_current_multiplier = 1,
  ac_current_divisor = 1000,
  ac_voltage_multiplier = 1,
  ac_voltage_divisor = 1,
  ac_power_multiplier = 1,
  ac_power_divisor = 1,
  metering_multiplier = 1,
  metering_divisor = 100,
}

local POWER_ON_BEHAVIOR_TO_ENUM = {
  off = 0,
  on = 1,
  restore = 2,
  previous = 2,
}

local POWER_ON_BEHAVIOR_FROM_ENUM = {
  [0] = "off",
  [1] = "on",
  [2] = "restore",
}

local POWER_OUTAGE_FIELD = "power_outage_memory"

local STARTUP_ONOFF_ATTR = zcl_clusters.OnOff.attributes.StartUpOnOff

local function safe_get_attribute(cluster, name)
  local ok, attr = pcall(function()
    return cluster.attributes[name]
  end)
  if ok then
    return attr
  end
  return nil
end

local MOES_STARTUP_ONOFF_ATTR = safe_get_attribute(zcl_clusters.OnOff, "MoesStartUpOnOff")
local POWER_ON_BEHAVIOR_ATTR = MOES_STARTUP_ONOFF_ATTR or STARTUP_ONOFF_ATTR

local function emit_component_event(device, component_id, event)
  local component = device.profile.components[component_id] or device.profile.components.main
  log_value_change(device, component_id, event)
  device:emit_component_event(component, event)
end

local function endpoint_for_component(component_id)
  return COMPONENT_TO_ENDPOINT[component_id] or 1
end

local function component_for_endpoint(endpoint)
  return ENDPOINT_TO_COMPONENT[endpoint] or "main"
end

local function emit_switch_event_for_endpoint(device, endpoint, event)
  local component_id = component_for_endpoint(endpoint)
  emit_component_event(device, component_id, event)
  local child = get_child_device(device, endpoint)
  if child then
    child:emit_event(event)
  end
end

local function set_persisted_field(device, key, value)
  if value == nil then
    return
  end
  device:set_field(key, value, { persist = true })
end

local function get_field_value(device, key, fallback)
  local value = device:get_field(key)
  if value == nil then
    return fallback
  end
  return value
end

local function scaled_value(raw, multiplier, divisor)
  local raw_number = tonumber(raw)
  if raw_number == nil then
    return nil
  end
  local mult = tonumber(multiplier) or 1
  local div = tonumber(divisor) or 1
  if div == 0 then
    return raw_number * mult
  end
  return (raw_number * mult) / div
end

local function switch_event(value)
  local is_on = value == true or value == 1
  return is_on and capabilities.switch.switch.on() or capabilities.switch.switch.off()
end

local function update_field_handler(field_key)
  return function(_, device, value)
    set_persisted_field(device, field_key, value.value)
  end
end

local function on_off_attr_handler(_, device, value, zb_rx)
  log_debug(device, "Zigbee RX OnOff: " .. format_zcl_body(zb_rx))
  local endpoint = zb_rx.address_header.src_endpoint.value
  emit_switch_event_for_endpoint(device, endpoint, switch_event(value.value))
end

local function power_on_behavior_attr_handler(_, device, value, zb_rx)
  log_debug(device, "Zigbee RX PowerOnBehavior: " .. format_zcl_body(zb_rx))
  local behavior = POWER_ON_BEHAVIOR_FROM_ENUM[value.value]
  if behavior then
    local previous = device:get_field(POWER_OUTAGE_FIELD)
    if previous ~= behavior then
      device:set_field(POWER_OUTAGE_FIELD, behavior, { persist = true })
      log_info(device, "Power outage memory set to " .. tostring(behavior))
    end
  end
end

local function active_power_attr_handler(_, device, value, zb_rx)
  log_debug(device, "Zigbee RX ActivePower: " .. format_zcl_body(zb_rx))
  local scaled = scaled_value(
    value.value,
    get_field_value(device, FIELD_KEYS.ac_power_multiplier, DEFAULTS.ac_power_multiplier),
    get_field_value(device, FIELD_KEYS.ac_power_divisor, DEFAULTS.ac_power_divisor)
  )
  if scaled ~= nil then
    emit_component_event(device, "main", capabilities.powerMeter.power({ value = scaled, unit = "W" }))
  end
end

local function rms_voltage_attr_handler(_, device, value, zb_rx)
  log_debug(device, "Zigbee RX RMSVoltage: " .. format_zcl_body(zb_rx))
  local scaled = scaled_value(
    value.value,
    get_field_value(device, FIELD_KEYS.ac_voltage_multiplier, DEFAULTS.ac_voltage_multiplier),
    get_field_value(device, FIELD_KEYS.ac_voltage_divisor, DEFAULTS.ac_voltage_divisor)
  )
  if scaled ~= nil then
    emit_component_event(device, "main", capabilities.voltageMeasurement.voltage(scaled))
  end
end

local function rms_current_attr_handler(_, device, value, zb_rx)
  log_debug(device, "Zigbee RX RMSCurrent: " .. format_zcl_body(zb_rx))
  local scaled = scaled_value(
    value.value,
    get_field_value(device, FIELD_KEYS.ac_current_multiplier, DEFAULTS.ac_current_multiplier),
    get_field_value(device, FIELD_KEYS.ac_current_divisor, DEFAULTS.ac_current_divisor)
  )
  if scaled ~= nil then
    emit_component_event(device, "main", capabilities.currentMeasurement.current(scaled))
  end
end

local function energy_attr_handler(_, device, value, zb_rx)
  log_debug(device, "Zigbee RX CurrentSummationDelivered: " .. format_zcl_body(zb_rx))
  local scaled = scaled_value(
    value.value,
    get_field_value(device, FIELD_KEYS.metering_multiplier, DEFAULTS.metering_multiplier),
    get_field_value(device, FIELD_KEYS.metering_divisor, DEFAULTS.metering_divisor)
  )
  if scaled ~= nil then
    emit_component_event(device, "main", capabilities.energyMeter.energy(scaled))
  end
end

local function send_zigbee_message(device, message, label)
  if not message then
    return
  end
  if label then
    log_debug(device, label .. ": " .. format_zcl_body(message))
  end
  device:send(message)
end

local function build_read_attributes_message(device, cluster_id, attr_ids)
  local read_body = read_attribute.ReadAttribute(attr_ids)
  local zclh = zcl_messages.ZclHeader({
    cmd = data_types.ZCLCommandId(read_attribute.ReadAttribute.ID),
  })
  local endpoint = device:get_endpoint(cluster_id) or device.fingerprinted_endpoint_id or 1
  local addrh = messages.AddressHeader(
    zb_const.HUB.ADDR,
    zb_const.HUB.ENDPOINT,
    device:get_short_address(),
    endpoint,
    zb_const.HA_PROFILE_ID,
    cluster_id
  )
  local message_body = zcl_messages.ZclMessageBody({
    zcl_header = zclh,
    zcl_body = read_body,
  })
  return messages.ZigbeeMessageTx({
    address_header = addrh,
    body = message_body,
  })
end

local function build_write_attribute_message(device, cluster_id, attr_id, data, endpoint)
  local write_body = write_attribute.WriteAttribute({
    write_attribute.WriteAttribute.AttributeRecord(attr_id, data_types.ZigbeeDataType(data.ID), data),
  })
  local zclh = zcl_messages.ZclHeader({
    cmd = data_types.ZCLCommandId(write_attribute.WriteAttribute.ID),
  })
  local dest_endpoint = endpoint or device:get_endpoint(cluster_id) or device.fingerprinted_endpoint_id or 1
  local addrh = messages.AddressHeader(
    zb_const.HUB.ADDR,
    zb_const.HUB.ENDPOINT,
    device:get_short_address(),
    dest_endpoint,
    zb_const.HA_PROFILE_ID,
    cluster_id
  )
  local message_body = zcl_messages.ZclMessageBody({
    zcl_header = zclh,
    zcl_body = write_body,
  })
  return messages.ZigbeeMessageTx({
    address_header = addrh,
    body = message_body,
  })
end

local function build_onoff_write_message(device, endpoint, data)
  local attr = zcl_clusters.OnOff.attributes.OnOff
  if attr and attr.write then
    return attr:write(device, data):to_endpoint(endpoint)
  end
  return build_write_attribute_message(
    device,
    zcl_clusters.OnOff.ID,
    data_types.AttributeId(attr and attr.ID or 0x0000),
    data,
    endpoint
  )
end

local function send_magic_packet(device)
  local attr_ids = {
    data_types.AttributeId(0x0004), -- ManufacturerName
    data_types.AttributeId(0x0000), -- ZCLVersion
    data_types.AttributeId(0x0001), -- ApplicationVersion
    data_types.AttributeId(0x0005), -- ModelIdentifier
    data_types.AttributeId(0x0007), -- PowerSource
    data_types.AttributeId(0xFFFE), -- Unknown (Tuya magic packet)
  }
  local message = build_read_attributes_message(device, zcl_clusters.Basic.ID, attr_ids)
  send_zigbee_message(device, message, "Zigbee TX Tuya magic packet")
end

local function refresh_measurements(device)
  local endpoint = 1
  send_zigbee_message(device, zcl_clusters.ElectricalMeasurement.attributes.ActivePower:read(device):to_endpoint(endpoint), "Zigbee TX ActivePower read")
  send_zigbee_message(device, zcl_clusters.ElectricalMeasurement.attributes.RMSVoltage:read(device):to_endpoint(endpoint), "Zigbee TX RMSVoltage read")
  send_zigbee_message(device, zcl_clusters.ElectricalMeasurement.attributes.RMSCurrent:read(device):to_endpoint(endpoint), "Zigbee TX RMSCurrent read")
  send_zigbee_message(device, zcl_clusters.SimpleMetering.attributes.CurrentSummationDelivered:read(device):to_endpoint(endpoint), "Zigbee TX CurrentSummationDelivered read")
end

local function refresh_switches(device)
  for endpoint, _ in pairs(ENDPOINT_TO_COMPONENT) do
    send_zigbee_message(device, zcl_clusters.OnOff.attributes.OnOff:read(device):to_endpoint(endpoint), "Zigbee TX OnOff read")
  end
end

local SWITCH_REFRESH_DELAY_SECONDS = 1

local function schedule_switch_refresh(device, delay_seconds)
  if not device or not device.thread then
    return
  end
  local delay = tonumber(delay_seconds) or SWITCH_REFRESH_DELAY_SECONDS
  device.thread:call_with_delay(delay, function()
    refresh_switches(device)
  end)
end

local function refresh_power_on_behavior(device)
  if not POWER_ON_BEHAVIOR_ATTR then
    return
  end
  send_zigbee_message(device, POWER_ON_BEHAVIOR_ATTR:read(device):to_endpoint(1), "Zigbee TX PowerOnBehavior read")
end

local function refresh_handler(_, device)
  log_debug(device, "Refresh command received")
  refresh_switches(device)
  refresh_measurements(device)
  refresh_power_on_behavior(device)
end

local function resolve_switch_target(device, component_id)
  if is_child_device(device) and device.get_parent_device then
    local parent = device:get_parent_device()
    local endpoint = tonumber(device.parent_assigned_child_key, 16)
    if parent and endpoint then
      return parent, endpoint
    end
  end
  return device, endpoint_for_component(component_id)
end

local function switch_handler(_, device, command)
  local target_device, endpoint = resolve_switch_target(device, command.component)
  local component_id = component_for_endpoint(endpoint)
  local is_on = command.command == "on"
  log_debug(device, string.format("Switch command %s on %s (endpoint %s)", command.command, component_id, tostring(endpoint)))
  local command_tx = is_on and zcl_clusters.OnOff.commands.On(target_device) or zcl_clusters.OnOff.commands.Off(target_device)
  send_zigbee_message(target_device, command_tx:to_endpoint(endpoint), "Zigbee TX OnOff")

  local write_tx = build_onoff_write_message(target_device, endpoint, data_types.Boolean(is_on))
  send_zigbee_message(target_device, write_tx, "Zigbee TX OnOff write (auto)")
  schedule_switch_refresh(target_device, 1)
end

local function apply_power_outage_memory(device, requested)
  if not POWER_ON_BEHAVIOR_ATTR then
    log_info(device, "Power-on behavior attribute not available for this device")
    return
  end
  if type(requested) == "string" then
    requested = string.lower(requested)
  end
  local enum_value = POWER_ON_BEHAVIOR_TO_ENUM[requested]
  if enum_value == nil then
    log_info(device, "Unsupported power outage memory: " .. tostring(requested))
    return
  end
  log_debug(device, "Setting power outage memory to " .. tostring(requested))
  local tx = POWER_ON_BEHAVIOR_ATTR:write(device, data_types.Enum8(enum_value))
  send_zigbee_message(device, tx:to_endpoint(1), "Zigbee TX PowerOnBehavior write")
end

local POLL_INTERVAL_SECONDS = 60
local POLL_TIMER_FIELD = "measurement_poll_timer"

local function schedule_measurement_poll(device)
  if device:get_field(POLL_TIMER_FIELD) then
    return
  end
  device:set_field(POLL_TIMER_FIELD, true)
  device.thread:call_with_delay(POLL_INTERVAL_SECONDS, function()
    device:set_field(POLL_TIMER_FIELD, nil)
    refresh_measurements(device)
    schedule_measurement_poll(device)
  end)
end

local function device_init(driver, device)
  if is_child_device(device) then
    return
  end
  log.error("Driver version: " .. DRIVER_VERSION)
  apply_log_level(device)
  device:set_component_to_endpoint_fn(function(_, component_id)
    return endpoint_for_component(component_id)
  end)
  device:set_endpoint_to_component_fn(function(_, endpoint)
    return component_for_endpoint(endpoint)
  end)
  if device.set_find_child then
    device:set_find_child(function(parent, endpoint)
      return get_child_device(parent, endpoint)
    end)
  end
  create_child_devices(driver, device)
  send_magic_packet(device)
  schedule_switch_refresh(device, 1)
  schedule_measurement_poll(device)
end

local function device_added(driver, device)
  if is_child_device(device) then
    return
  end
  apply_log_level(device)
  create_child_devices(driver, device)
  send_magic_packet(device)
  refresh_switches(device)
  schedule_switch_refresh(device, 1)
  refresh_measurements(device)
  refresh_power_on_behavior(device)
end

local function do_configure(driver, device)
  if is_child_device(device) then
    return
  end
  apply_log_level(device)
  local hub_eui = driver.environment_info.hub_zigbee_eui
  send_magic_packet(device)

  for endpoint, _ in pairs(ENDPOINT_TO_COMPONENT) do
    local bind_request = device_management.build_bind_request(device, zcl_clusters.OnOff.ID, hub_eui)
    send_zigbee_message(device, bind_request:to_endpoint(endpoint), "Zigbee TX OnOff bind")
    send_zigbee_message(device, zcl_clusters.OnOff.attributes.OnOff:configure_reporting(device, 0, 600):to_endpoint(endpoint), "Zigbee TX OnOff reporting")
  end

  local measurement_endpoint = 1
  local electrical_bind = device_management.build_bind_request(device, zcl_clusters.ElectricalMeasurement.ID, hub_eui)
  send_zigbee_message(device, electrical_bind:to_endpoint(measurement_endpoint), "Zigbee TX ElectricalMeasurement bind")
  local metering_bind = device_management.build_bind_request(device, zcl_clusters.SimpleMetering.ID, hub_eui)
  send_zigbee_message(device, metering_bind:to_endpoint(measurement_endpoint), "Zigbee TX SimpleMetering bind")

  send_zigbee_message(device, zcl_clusters.ElectricalMeasurement.attributes.ActivePower:configure_reporting(device, 5, 300, 1):to_endpoint(measurement_endpoint), "Zigbee TX ActivePower reporting")
  send_zigbee_message(device, zcl_clusters.ElectricalMeasurement.attributes.RMSVoltage:configure_reporting(device, 5, 300, 1):to_endpoint(measurement_endpoint), "Zigbee TX RMSVoltage reporting")
  send_zigbee_message(device, zcl_clusters.ElectricalMeasurement.attributes.RMSCurrent:configure_reporting(device, 5, 300, 1):to_endpoint(measurement_endpoint), "Zigbee TX RMSCurrent reporting")
  send_zigbee_message(device, zcl_clusters.SimpleMetering.attributes.CurrentSummationDelivered:configure_reporting(device, 30, 900, 1):to_endpoint(measurement_endpoint), "Zigbee TX CurrentSummationDelivered reporting")

  send_zigbee_message(device, zcl_clusters.ElectricalMeasurement.attributes.ACPowerMultiplier:read(device):to_endpoint(measurement_endpoint), "Zigbee TX ACPowerMultiplier read")
  send_zigbee_message(device, zcl_clusters.ElectricalMeasurement.attributes.ACPowerDivisor:read(device):to_endpoint(measurement_endpoint), "Zigbee TX ACPowerDivisor read")
  send_zigbee_message(device, zcl_clusters.ElectricalMeasurement.attributes.ACVoltageMultiplier:read(device):to_endpoint(measurement_endpoint), "Zigbee TX ACVoltageMultiplier read")
  send_zigbee_message(device, zcl_clusters.ElectricalMeasurement.attributes.ACVoltageDivisor:read(device):to_endpoint(measurement_endpoint), "Zigbee TX ACVoltageDivisor read")
  send_zigbee_message(device, zcl_clusters.ElectricalMeasurement.attributes.ACCurrentMultiplier:read(device):to_endpoint(measurement_endpoint), "Zigbee TX ACCurrentMultiplier read")
  send_zigbee_message(device, zcl_clusters.ElectricalMeasurement.attributes.ACCurrentDivisor:read(device):to_endpoint(measurement_endpoint), "Zigbee TX ACCurrentDivisor read")
  send_zigbee_message(device, zcl_clusters.SimpleMetering.attributes.Multiplier:read(device):to_endpoint(measurement_endpoint), "Zigbee TX Metering Multiplier read")
  send_zigbee_message(device, zcl_clusters.SimpleMetering.attributes.Divisor:read(device):to_endpoint(measurement_endpoint), "Zigbee TX Metering Divisor read")

  refresh_switches(device)
  schedule_switch_refresh(device, 1)
  refresh_measurements(device)
  refresh_power_on_behavior(device)
end

local function info_changed(driver, device, _, args)
  if is_child_device(device) then
    return
  end
  apply_log_level(device)
  local level = normalize_log_level(device.preferences and device.preferences.logLevel)
  log_info(device, "Log level set to " .. level)
  local old_prefs = args and args.old_st_store and args.old_st_store.preferences or {}
  local new_pref = device.preferences and device.preferences.powerOutageMemory
  if new_pref and new_pref ~= old_prefs.powerOutageMemory then
    apply_power_outage_memory(device, new_pref)
  end
  local new_child_pref = device.preferences and device.preferences[CHILD_SWITCH_PREF]
  if new_child_pref == true and new_child_pref ~= old_prefs[CHILD_SWITCH_PREF] then
    create_child_devices(driver, device)
  end
end

local driver = zigbee_driver("wp30-eu-plug", {
  supported_capabilities = {
    capabilities.switch,
    capabilities.powerMeter,
    capabilities.energyMeter,
    capabilities.voltageMeasurement,
    capabilities.currentMeasurement,
    capabilities.refresh,
  },
  zigbee_handlers = {
    attr = {
      [zcl_clusters.OnOff.ID] = {
        [zcl_clusters.OnOff.attributes.OnOff.ID] = on_off_attr_handler,
        [POWER_ON_BEHAVIOR_ATTR and POWER_ON_BEHAVIOR_ATTR.ID or 0xFFFF] = power_on_behavior_attr_handler,
      },
      [zcl_clusters.ElectricalMeasurement.ID] = {
        [zcl_clusters.ElectricalMeasurement.attributes.ActivePower.ID] = active_power_attr_handler,
        [zcl_clusters.ElectricalMeasurement.attributes.RMSVoltage.ID] = rms_voltage_attr_handler,
        [zcl_clusters.ElectricalMeasurement.attributes.RMSCurrent.ID] = rms_current_attr_handler,
        [zcl_clusters.ElectricalMeasurement.attributes.ACPowerMultiplier.ID] = update_field_handler(FIELD_KEYS.ac_power_multiplier),
        [zcl_clusters.ElectricalMeasurement.attributes.ACPowerDivisor.ID] = update_field_handler(FIELD_KEYS.ac_power_divisor),
        [zcl_clusters.ElectricalMeasurement.attributes.ACVoltageMultiplier.ID] = update_field_handler(FIELD_KEYS.ac_voltage_multiplier),
        [zcl_clusters.ElectricalMeasurement.attributes.ACVoltageDivisor.ID] = update_field_handler(FIELD_KEYS.ac_voltage_divisor),
        [zcl_clusters.ElectricalMeasurement.attributes.ACCurrentMultiplier.ID] = update_field_handler(FIELD_KEYS.ac_current_multiplier),
        [zcl_clusters.ElectricalMeasurement.attributes.ACCurrentDivisor.ID] = update_field_handler(FIELD_KEYS.ac_current_divisor),
      },
      [zcl_clusters.SimpleMetering.ID] = {
        [zcl_clusters.SimpleMetering.attributes.CurrentSummationDelivered.ID] = energy_attr_handler,
        [zcl_clusters.SimpleMetering.attributes.Multiplier.ID] = update_field_handler(FIELD_KEYS.metering_multiplier),
        [zcl_clusters.SimpleMetering.attributes.Divisor.ID] = update_field_handler(FIELD_KEYS.metering_divisor),
      },
    },
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      on = switch_handler,
      off = switch_handler,
    },
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
