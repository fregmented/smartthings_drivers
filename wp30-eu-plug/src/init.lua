local capabilities = require "st.capabilities"
local zigbee_driver = require "st.zigbee"
local data_types = require "st.zigbee.data_types"
local generic_body = require "st.zigbee.generic_body"

require "overridden"

local TuyaEF00 = require "st.zigbee.generated.zcl_clusters.TuyaEF00"

local MODEL = {
  deviceLabel = "Power Strip",
  profiles = {
    "normal_multi_switch_powerMeter_v1",
    "normal_multi_switch_v3",
    "switch_all_multi_switch_v3",
    "custom_multi_switch_v3",
  },
  datapoints = {
    { id = 1, command = "switch", base = { group = 1 } },
    { id = 2, command = "switch", base = { group = 2 } },
    { id = 3, command = "switch", base = { group = 3 } },
    { id = 18, command = "currentMeasurement", base = { group = 1, rate = 10000 } },
    { id = 19, command = "powerMeter", base = { group = 1, rate = 1000 } },
    { id = 20, command = "voltageMeasurement", base = { group = 1, rate = 1000 } },
    { id = 101, command = "energyMeter", base = { group = 1, rate = 10000 } },
  },
}

local GROUP_TO_COMPONENT = {
  [1] = "main",
  [2] = "l2",
  [3] = "l3",
}

local function get_value(data)
  if getmetatable(data) == generic_body.GenericBody then
    return data:_serialize()
  end
  return data.value
end

local function switch_event(value)
  local is_on = value == true or value == 1
  return is_on and capabilities.switch.switch.on() or capabilities.switch.switch.off()
end

local function scaled_value(raw, scale, divisor)
  return (scale * raw) / divisor
end

local COMMANDS = {
  switch = {
    to_event = function(value)
      return switch_event(value)
    end,
  },
  currentMeasurement = {
    to_event = function(value, base)
      return capabilities.currentMeasurement.current(scaled_value(value, 10, base.rate or 10000))
    end,
  },
  powerMeter = {
    to_event = function(value, base)
      return capabilities.powerMeter.power({ value = scaled_value(value, 100, base.rate or 1000), unit = "W" })
    end,
  },
  voltageMeasurement = {
    to_event = function(value, base)
      return capabilities.voltageMeasurement.voltage(scaled_value(value, 100, base.rate or 1000))
    end,
  },
  energyMeter = {
    to_event = function(value, base)
      return capabilities.energyMeter.energy(scaled_value(value, 10, base.rate or 10000))
    end,
  },
}

local function build_dp_defs(model)
  local defs = {}
  for _, dp in ipairs(model.datapoints or {}) do
    local base = dp.base or {}
    local group = base.group or dp.id
    local command = COMMANDS[dp.command]
    if command then
      local base_copy = base
      local command_copy = command
      defs[dp.id] = {
        component = GROUP_TO_COMPONENT[group] or "main",
        to_event = function(value)
          return command_copy.to_event(value, base_copy)
        end,
      }
    end
  end
  return defs
end

local function build_switch_dps(model)
  local map = {}
  for _, dp in ipairs(model.datapoints or {}) do
    if dp.command == "switch" then
      local base = dp.base or {}
      local group = base.group or dp.id
      local component = GROUP_TO_COMPONENT[group] or "main"
      map[component] = dp.id
    end
  end
  return map
end

local DP_DEFS = build_dp_defs(MODEL)
local SWITCH_DPS = build_switch_dps(MODEL)

local function emit_component_event(device, component_id, event)
  local component = device.profile.components[component_id] or device.profile.components.main
  device:emit_component_event(component, event)
end

local function tuya_dp_handler(driver, device, zb_rx)
  for _, data in ipairs(zb_rx.body.zcl_body.data_list or {}) do
    local def = DP_DEFS[data.dpid.value]
    if def then
      local event = def.to_event(get_value(data.value))
      if event then
        emit_component_event(device, def.component, event)
      end
    end
  end
end

local function switch_handler(driver, device, command)
  local dpid = SWITCH_DPS[command.component]
  if not dpid then
    return
  end
  local is_on = command.command == "on"
  device:send(TuyaEF00.commands.DataRequest(device, { { dpid, data_types.Boolean(is_on) } }))
end

local function refresh_handler(driver, device, command)
  device:send(TuyaEF00.commands.DataQuery(device))
end

local function device_added(driver, device)
  device:send(TuyaEF00.commands.GatewayData(device))
  device.thread:call_with_delay(1, function()
    device:send(TuyaEF00.commands.DataQuery(device))
  end)
end

local function gateway_status_handler(driver, device, zb_rx)
  local transid = zb_rx.body.zcl_body.transid.value
  device:send(TuyaEF00.commands.GatewayStatus(device, transid))
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
    cluster = {
      [TuyaEF00.ID] = {
        [TuyaEF00.commands.DataResponse.ID] = tuya_dp_handler,
        [TuyaEF00.commands.DataReport.ID] = tuya_dp_handler,
        [TuyaEF00.commands.StatusReport.ID] = tuya_dp_handler,
        [TuyaEF00.commands.StatusReportAlt.ID] = tuya_dp_handler,
        [TuyaEF00.commands.GatewayStatus.ID] = gateway_status_handler,
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
    added = device_added,
  },
})

driver:run()
