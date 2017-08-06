_Config = {
  SSID = "",
  WifiPass = "",
  mqttBroker = "",
  mqttPort = 1883,
  mqttUser = "",
  mqttPass = "",
  deviceID = "",
  roomID = ""
}

_pinConfig = {
  mqttLed = 7,
  relayPin = 6,
  buttonPin = 3,
  switchPin = 5,
  --Debounce Settings
  buttonDebounce = 500,
  switchdebounce = 500
}

m = nil;
connected = false;
wifiConnectAttempts = 0;

function setupPins()
  -- Pin which the relay is connected to
  gpio.mode(_pinConfig.relayPin, gpio.OUTPUT)
  gpio.write(_pinConfig.relayPin, gpio.LOW)

  -- Connected to switch with internal pullup enabled
  gpio.mode(_pinConfig.buttonPin, gpio.INPUT, gpio.PULLUP)

  -- Connected to switch with internal pullup enabled
  gpio.mode(_pinConfig.switchPin, gpio.INPUT, gpio.PULLUP)

  -- MQTT led
  gpio.mode(_pinConfig.mqttLed, gpio.OUTPUT)
  gpio.write(_pinConfig.mqttLed, gpio.HIGH)
end

-- Read Configuration file, return if file is found
function readConfig ()
  local fileExists = file.exists("device.config");

  if(fileExists) then
    print("Config file exists, reading Config...")

    file.open("device.config", "r")

    _, _, _Config.SSID = string.find(file.readline(), "([%w.]+)");
    _, _, _Config.WifiPass = string.find(file.readline(), "([%w.]+)");
    _, _, _Config.mqttBroker = string.find(file.readline(), "([%w.]+)");
    _, _, _Config.mqttUser = string.find(file.readline(), "([%w.]+)");
    _, _, _Config.mqttPass = string.find(file.readline(), "([%w.]+)");
    _, _, _Config.deviceID = string.find(file.readline(), "([%w.]+)");
    _, _, _Config.roomID = string.find(file.readline(), "([%w.]+)");

    file.close()
  end

  return fileExists and not file.exists("cantConnect");
end

function readCSS()
  local cssString = "<style>";

  if(file.exists("dark.css")) then
    file.open("dark.css", "r")

    cssString = cssString..file.read();

    file.close()
  end

  cssString = cssString .. "</style>";

  return cssString;
end
-- Connect to WIFI
function connectToWifi()
  wifi.setmode(wifi.STATION)
  wifi.sta.config (_Config.SSID, _Config.WifiPass)

  print("Connected to Wifi");

  tmr.alarm(0, 1000, 1, function()
    --print("Wifi Status:"..wifi.sta.status());

    --If we cant connect write a file
    if(wifiConnectAttempts > 10 and not file.exists("cantConnect")) then
        file.open("cantConnect", "w");
        file.writeline("Cant Connect");
        file.close();
    end

    if wifi.sta.status() == 5 and wifi.sta.getip() ~= nil then
      --If we can connect remove the file
      if(file.exists("cantConnect")) then
        file.remove("cantConnect", "w");
      end

      print("MAC:"..wifi.sta.getmac().."\r\nIP:"..wifi.sta.getip());

      -- check if mqtt client is nil else open connection
      if(m ~= nil) then
        tmr.stop(0)

        m:connect(_Config.mqttBroker, _Config.mqttPort, 0, function(conn)
          gpio.write(_pinConfig.mqttLed, gpio.HIGH)
          print("MQTT connected to: " .. _Config.mqttBroker .. ":" .. _Config.mqttPort);
          mqtt_sub() -- run the subscription function
          connected = true;
        end)
      end
    else
      wifiConnectAttempts = wifiConnectAttempts + 1;
    end
   end)
end

function broadCastWifiSSID()
  print("Ready to start soft ap")

  local str=wifi.ap.getmac();
  local ssidTemp=string.format("%s%s%s",string.sub(str,10,11),string.sub(str,13,14),string.sub(str,16,17));

  cfg={}
  cfg.ssid="Sonoff_"..ssidTemp;
  cfg.pwd="12345678"
  wifi.ap.config(cfg)

  cfg={}
  cfg.ip="192.168.1.1";
  cfg.netmask="255.255.255.0";
  cfg.gateway="192.168.1.1";
  wifi.ap.setip(cfg);
  wifi.setmode(wifi.SOFTAP)

  str=nil;
  ssidTemp=nil;
  collectgarbage();

  print("Soft AP started")
  print("MAC:"..wifi.ap.getmac().."\r\nIP:"..wifi.ap.getip());
end

-- Connect to MQTT Server
function setupMqttClient()
  print("Attempting MQTT Connect with '" .. "Sonoff-" .. _Config.roomID .. _Config.deviceID .. "'...");

  m = mqtt.Client("Sonoff-" .. _Config.roomID .. _Config.deviceID, 180, _Config.mqttUser, _Config.mqttPass)
  m:lwt("/lwt", "Sonoff " .. _Config.roomID .. _Config.deviceID, 0, 0)
  m:on("offline", function(con)
      ip = wifi.sta.getip()
      print ("MQTT reconnecting to " .. _Config.mqttBroker .. " from " .. ip)
      tmr.alarm(1, 10000, 0, function()
          print ("cannot connect check RoomId and DeviceId, restarting...")
          node.restart();
      end)
  end)

  -- On publish message receive event
  m:on("message", function(conn, topic, data)
      mqttAct()
      print("Recieved:" .. topic .. ":" .. data)
      if (data=="ON") then
        updateRelay(1);
      elseif (data=="OFF") then
        updateRelay(0)
      else
        print("Invalid command (" .. data .. ")")
      end
      mqtt_update()
  end)
end

-- Make a short flash with the led on MQTT activity
function mqttAct()
    if (gpio.read(_pinConfig.mqttLed) == 1) then
      gpio.write(_pinConfig.mqttLed, gpio.HIGH)
    end

    gpio.write(_pinConfig.mqttLed, gpio.LOW)
    tmr.alarm(5, 50, 0, function()
      gpio.write(_pinConfig.mqttLed, gpio.HIGH)
    end)
end

-- Update status to MQTT
function mqtt_update()
    if (gpio.read(_pinConfig.relayPin) == 0) then
        m:publish("/home/".. _Config.roomID .."/" .. _Config.deviceID .. "/state","OFF",0,0)
    else
        m:publish("/home/".. _Config.roomID .."/" .. _Config.deviceID .. "/state","ON",0,0)
    end
end

-- Subscribe to MQTT
function mqtt_sub()
    mqttAct()
    m:subscribe("/home/".. _Config.roomID .."/" .. _Config.deviceID,0, function(conn)
        print("MQTT subscribed to /home/".. _Config.roomID .."/" .. _Config.deviceID)
    end)
end

function startWebServer()
  print("Starting Web Server")
  srv=net.createServer(net.TCP)
  srv:listen(80,function(conn)
      conn:on("receive", function(client,request)
          print("Received "..request)
          local buf = "";
          local _, _, method, path, vars = string.find(request, "([A-Z]+) (.+)?(.+) HTTP");
          if(method == nil)then
              _, _, method, path = string.find(request, "([A-Z]+) (.+) HTTP");
          end
          local _GET = {}
          if (vars ~= nil)then
              for k, v in string.gmatch(vars, "(%w+)=([^=&]+)&*") do
                  _GET[k] = v
              end
          end

          if(_GET.SSID ~= nil) then

              print("Writing Settings...")
              file.open("device.config", "w");

              file.writeline("~~".._GET.SSID.."~~");
              file.writeline("~~".._GET.WifiPass.."~~");
              file.writeline("~~".._GET.Broker.."~~");
              file.writeline("~~".._GET.MQTTUser.."~~");
              file.writeline("~~".._GET.MQTTPass.."~~");
              file.writeline("~~".._GET.DeviceId.."~~");
              file.writeline("~~".._GET.Room.."~~");

              file.close();
              node.restart();
          elseif(connected and _GET.switch ~= nil) then
            updateRelay();
          end

          local buf = "";

          --HTML Headers
          buf = buf.."<!doctype html>";
          buf = buf.."<html lang='en'>";
          buf = buf.."<head>";
          buf = buf.."<meta charset='utf-8'>";
          buf = buf.."<title>Sonoff Wifi with MQTT</title>";

          --Clear Buffer and Collect Garbage so we dont run out of memory
          conn:send(buf, function()
            collectgarbage();

            --Send CSS File as inline css
            conn:send(readCSS(), function()
              collectgarbage();

              --Build next set of data and send
              local buf2 = "</head>";
              buf2 = buf2.."<body>";
              buf2 = buf2.."<div class='container'>";
              buf2 = buf2.."<div class='row'>";
              buf2 = buf2.."<div class='col-sm-12 col-md-8 col-lg-6'>";
              buf2 = buf2.."<h1>Sonoff Wifi and MQTT Setup</h1>";
              if(not connected) then
                buf2 = buf2.."<div style='background-color: red'>MQTT not connected</div>";
              else
                buf2 = buf2.."<div style='background-color: green'>MQTT connected</div>";
              end
              buf2 = buf2.."<form id='configform'>";
              conn:send(buf2, function()
                collectgarbage();

                --Fieldset 1 for WIFI
                local buf3 = "<fieldset>";
                buf3 = buf3.."<legend>Wifi</legend>";
                buf3 = buf3.."<div class='input-group fluid'>";
                buf3 = buf3.."<label for='SSID' style='width: 80px;'>Wifi SSID</label>";
                buf3 = buf3.."<input id='SSID' name='SSID' value='" .. _Config.SSID .. "' placeholder='Wifi SSID'>";
                buf3 = buf3.."</div>";
                buf3 = buf3.."<div class='input-group fluid'>";
                buf3 = buf3.."<label for='WifiPassword' style='width: 80px;'>Password</label>";
                buf3 = buf3.."<input id='WifiPassword' type='password' name='WifiPass' value='" .. _Config.WifiPass .. "' placeholder='Wifi Password'>";
                buf3 = buf3.."</div>";
                buf3 = buf3.."</fieldset>";

                conn:send(buf3, function()
                  collectgarbage();

                  local buf4 = "<fieldset>";
                  buf = buf4.."<legend>MQTT</legend>";
                  buf4 = buf4.."<div class='input-group fluid'>";
                  buf4 = buf4.."<label for='Broker' style='width: 80px;'>Broker IP</label>";
                  buf4 = buf4.."<input id='Broker' name='Broker' value='" .. _Config.mqttBroker .. "' placeholder='MQTT Broker IP Address'>";
                  buf4 = buf4.."</div>";
                  buf4 = buf4.."<div class='input-group fluid'>";
                  buf4 = buf4.."<label for='MQTTUser' style='width: 80px;'>User Name</label>";
                  buf4 = buf4.."<input id='MQTTUser' name='MQTTUser' value='" .. _Config.mqttUser .. "' placeholder='MQTT User Name'>";
                  buf4 = buf4.."</div>";
                  buf4 = buf4.."<div class='input-group fluid'>";
                  buf4 = buf4.."<label for='MQTTPass' style='width: 80px;'>Password</label>";
                  buf4 = buf4.."<input type='password' id='MQTTPass' name='MQTTPass' value='" .. _Config.mqttPass .. "' placeholder='MQTT Password'>";
                  buf4 = buf4.."</div>";
                  buf4 = buf4.."</fieldset>";

                  conn:send(buf4, function()
                    collectgarbage();

                    local buf5 = "<fieldset>";
                    buf5 = buf5.."<legend>Device</legend>";
                    buf5 = buf5.."<div class='input-group fluid'>";
                    buf5 = buf5.."<label for='DeviceId' style='width: 80px;'>Device ID</label>";
                    buf5 = buf5.."<input id='DeviceId' name='DeviceId' value='" .. _Config.deviceID .. "' placeholder='Device ID'>";
                    buf5 = buf5.."</div>";
                    buf5 = buf5.."<div class='input-group fluid'>";
                    buf5 = buf5.."<label for='Room' style='width: 80px;'>Room</label>";
                    buf5 = buf5.."<input id='Room' name='Room' value='" .. _Config.roomID .. "' placeholder='Room'>";
                    buf5 = buf5.."</div>";
                    buf5 = buf5.."</fieldset>";
                    buf5 = buf5.."<fieldset>";
                    buf5 = buf5.."<div class='input-group fluid'>";
                    buf5 = buf5.."<button type='submit' onclick='' form='configform'>Save and Restart</button>";

                    --[[
                    if(connected) then
                      if(gpio.read(_pinConfig.relayPin) == 1) then
                        buf5 = buf5.."<button type='submit' onclick='' form='switchform'>Turn Off</button>";
                      else
                        buf5 = buf5.."<button type='submit' onclick='' form='switchform'>Turn On</button>";
                      end
                    end
                    ]]--

                    buf5 = buf5.."</div>";
                    buf5 = buf5.."</fieldset>";
                    buf5 = buf5.."</form>";

                    --[[
                    if(connected) then
                      buf5 = buf5.."<form class='hidden' id='switchform' name='switchform' action='WebTest.html/state'>";
                      if(gpio.read(_pinConfig.relayPin) == 1) then
                        buf5 = buf5.."<input id='switch' type='hidden' name='switch' value='OFF'/>";
                      else
                        buf5 = buf5.."<input id='switch' type='hidden' name='switch' value='ON'/>";
                      end
                      buf5 = buf5.."</form>";
                    end
                    ]]--
                    buf5 = buf5.."</div>";
                    buf5 = buf5.."<div class='col-sm'>";
                    buf5 = buf5.."</div>";

                    buf5 = buf5.."</div>";
                    buf5 = buf5.."</div>";

                    buf5 = buf5.."</body>";
                    buf5 = buf5.."</html>";

                    conn:send(buf5, function()--sk)
                      collectgarbage();
                      --sk:close();
                    end)
                  end)
                end)
              end)
            end)
          end)

          --client:close();
          collectgarbage();

      end)
  end)
end

function updateRelay(state)
  --Change the state
  if ((state ~= nil and state == 0) or gpio.read(_pinConfig.relayPin) == 1) then
      gpio.write(_pinConfig.relayPin, gpio.LOW)
      print("Switch Was on, turning off")
  else
      gpio.write(_pinConfig.relayPin, gpio.HIGH)
      print("Switch Was off, turning on")
  end

  mqttAct()
  mqtt_update()
end

--[[
function displaySettings()
  print("SSID: '".._Config.SSID.."'");
  print("WifiPass: '".._Config.WifiPass.."'");
  print("mqttBroker: '".._Config.mqttBroker.."'");
  print("mqttUser: '".._Config.mqttUser.."'");
  print("mqttPass: '".._Config.mqttPass.."'");
  print("deviceID: '".._Config.deviceID.."'");
  print("roomID: '".._Config.roomID.."'");
end
]]--

setupPins();

if readConfig() then
  --Display the Settings
  --displaySettings();

  --Connect to the wifi network
  connectToWifi();

  --Conntect to MQTT broker
  setupMqttClient();

  -- Pin to toggle the status
  buttondebounced = 0
  gpio.trig(_pinConfig.buttonPin, "down",function (level)
    if (buttondebounced == 0) then
      buttondebounced = 1
      tmr.alarm(6, _pinConfig.buttonDebounce, 0, function() buttondebounced = 0; end)

      updateRelay();
    end
  end)

  -- Pin to toggle the status
  switchdebounced = 0
  switchState = 0
  gpio.trig(_pinConfig.switchPin, "both", function (level)
    if(switchState ~= gpio.read(_pinConfig.switchPin)) then
      switchState = gpio.read(_pinConfig.switchPin)

      if (switchdebounced == 0) then
        switchdebounced = 1
        tmr.alarm(6, _pinConfig.switchdebounce, 0, function() switchdebounced = 0; end)
        --print(gpio.read(_pinConfig.switchPin))
        updateRelay();
      end
    end
  end)
else
  broadCastWifiSSID();
  gpio.mode(_pinConfig.mqttLed, gpio.OUTPUT)
end

startWebServer();
