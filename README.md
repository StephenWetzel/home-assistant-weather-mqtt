Send local area weather station data to Home Assistant via MQTT
====


## What is it?
A way to pull in aggregate weather data from nearby Ambient Weather personal weather stations, and send median (or other percentile) values to [Home Assistant](https://www.home-assistant.io/) via MQTT.


## Background
I have a personal [weather station](https://smile.amazon.com/gp/product/B01N5TEHLI), which tells me things like temperature and rain in my backyard.  It also has a UV meter on it, however, there is no great place to [mount a weather station at my house](https://www.weatherstationadvisor.com/weather-station-mounting-ideas-and-solutions/), and the location I am using gets shadows at times throughout the day.  This means the UV measurement from my meter is not very useful.

Most of these weather stations publish their data and you can get them from an API, so I came up with the idea to find a near by weather station, which gets less shadows, and to use the UV data from that one.  Over time, I found that there were no stations which never had drop offs, likely from shadows.  My solution was to have a few and then take the highest of them.  I eventually decided to automate this so I could get the data into my [Home Assistant](https://www.home-assistant.io/) instance.



## Setup
You will need to have Home Assistant and MQTT set up already, as well as a machine you can run Ruby on (like a Raspberry Pi).

### Configuration
1. `git clone https://github.com/StephenWetzel/home-assistant-weather-mqtt.git`
2. `cd home-assistant-weather-mqtt`
4. Go to [https://ambientweather.net/](https://ambientweather.net/) and see what weather stations are in the area you want to monitor.  I'd recommend choosing an area with between 10 and 100 stations, depending on how densely populated your area is.
5. Us a tool like [this](http://bboxfinder.com/) to draw a rectangle over the area you want monitor.  Get the latitude and longitude for the south west (bottom left) and north east (top right) corners.
6. Put those coordinates and your MQTT broker details in an `.env` file in the same folder as the Ruby script.
```
MQTT_BROKER_HOST = '192.168.1.123'
MQTT_USERNAME = 'my_mqtt_user'
MQTT_PASSWORD = 'password123'
SOUTH_WEST_LAT = '-75.193434'
SOUTH_WEST_LONG = '39.928695'
NORTH_EAST_LAT = '-75.133610'
NORTH_EAST_LONG = '39.970345'
```

### If you need Ruby
You have two paths here, either use the system Ruby or use something like [`rbenv`](https://github.com/rbenv/rbenv) to do it "the right way" which will allow you to install different versions of Ruby for different projects.  If you have no intentions of using Ruby outside of this script, and just want it to work it'll be easier to use the system Ruby, but just know that you'll have to run everything with `sudo` and you run the risk of messing something up on your system.

### Using rbenv
This is your first option
1. `sudo apt install rbenv`
1. `rbenv init`
1. `rbenv install -l` to see the available versions of Ruby
1. `rbenv install 2.7.1` You should be fine with a newer version, but this is what I'm using as I write these directions.  This takes awhile to run on a Raspberry Pi
1. `rbenv local 2.7.1` ensure you are inside the project directory
1. Confirm you have the correct version with `ruby --version`
1. `gem install bundler`
1. `bundle install`

### Using sudo
This is the second option
1. `sudo apt install ruby-full`
1. `sudo gem install bundler`
1. `sudo bundle install`

### Running
1. Run with `ruby local_to_mqtt.rb`, you'll have to use `sudo` if you used the system Ruby above
1. Check in Home Assistant for the new entities, which should appear as long as you have [MQTT discovery enabled](https://www.home-assistant.io/docs/mqtt/discovery/)
1. Figure out how you want to run the script automatically on boot.  If you set it up as `sudo` you can just add it here: `sudo nano /etc/rc.local`.  If you're running it with `rbenv` you can run it as your user on boot by putting it in your crontab and using the special keyword `@reboot` instead of the typical time pattern.  However, you'll run into the problem that your `rbenv` version of Ruby isn't available in cron.  You can one of the solutions [noted in this stack overflow answer](https://stackoverflow.com/questions/8434922/how-to-run-a-ruby-script-using-rbenv-with-cron) to get around this.

## Options
Running with `--help` or `-h` will show the available command line options.  All of these can be left off as they have default values.
```
ruby local_to_mqtt.rb -h
Usage: local_to_mqtt.rb [options]
    -l, --limit LIMIT                Limit to the number of stations to check
    -f, --update_frequency FREQ      Time between refreshes, in seconds
    -m, --max_age AGE                Maximum age of data to collect, in seconds
    -p, --discovery_prefix PREFIX    The home assistant discovery prefix
    -d, --debug [FLAG]               Set to true to print debug logs to console while running
    -n, --no_send [FLAG]             Set to true to prevent sending data to MQTT
```


## Changing what data you collect
By default it will monitor UV (the median, 90th percentile, and max values), and the median "feels like" temperature.  What it's monitoring can be changed by modifying the `keys_to_collect.json` config file.  Here is what it looks like by default:
```
[
  {
    "aw_key_name": "uv",
    "percentile": 100,
    "unit": "UV index",
    "device_class": "illuminance",
    "mqtt_name": "area_uv_max"
  },
  {
    "aw_key_name": "uv",
    "percentile": 90,
    "unit": "UV index",
    "device_class": "illuminance",
    "mqtt_name": "area_uv_90_percentile"
  },
  {
    "aw_key_name": "uv",
    "percentile": 50,
    "unit": "UV index",
    "device_class": "illuminance",
    "mqtt_name": "area_uv_median"
  },
  {
    "aw_key_name": "feelsLike",
    "percentile": 50,
    "unit": "°F",
    "device_class": "temperature",
    "mqtt_name": "area_feels_like_median"
  }
]

```

The easiest way to see what data is available is to just take a look at the API for your area.  [This is the endpoint this script uses](https://lightning.ambientweather.net/devices?$publicBox[0][0]=-75.193434&$publicBox[0][1]=39.928695&$publicBox[1][0]=-75.133610&$publicBox[1][1]=39.970345&$limit=100).

There you should be able to see both how many stations are in the area you've chosen, and what data is available (in the `lastData` key).  Here is a typical example:

```
"baromrelin": 29.853
"baromabsin": 29.853
"tempf": 76.6
"humidity": 92
"winddir": 111
"winddir_avg10m": 107
"windspeedmph": 0
"windspdmph_avg10m": 0
"windgustmph": 0
"maxdailygust": 3.4
"hourlyrainin": 0
"eventrainin": 0
"dailyrainin": 0
"weeklyrainin": 0.008
"monthlyrainin": 0.331
"yearlyrainin": 30.327
"solarradiation": 0
"uv": 0
"type": "weather-data"
"feelsLike": 78.28399999999999
"dewPoint": 74.09448451913397
 ```

Here are the [Ambient Weather docs](https://github.com/ambient-weather/api-docs/wiki/Device-Data-Specs) on what these keys represent.

Let's say you want to add collect wind speed.  Looking at the above example we can see there are a few options to choose from.  You can look at the docs, or just figure out what the differences are based on the names.  You can always choose a few to pull into Home Assistant and then decide which is best after a few days.

To monitor instantaneous wind speed you'd add this row to the `keys_to_collect` variable:
```
  {
    "aw_key_name": "windspeedmph",
    "percentile": 50,
    "unit": "mph",
    "mqtt_name": "area_wind_speed"
  }
```

Where:
* `aw_key_name` - is the name of the key from the Ambient Weather API
* `percentile` - is which percentile you want to take the reading of, from 0 (lowest) to 100 (highest).  For example, if you had 10 values: `[10, 10, 10, 10, 12, 13, 14, 15, 16, 20]`, then the 10th percentile would be `10`, and the 90th percentile would be `16.4`.  The 0th percentile will always be the minimum value, the 100th percentile the maximum value, and the 50th percentile the median value.
* `unit` - what unit to send to Home Assistant.  Refer to the [Ambient Weather docs](https://github.com/ambient-weather/api-docs/wiki/Device-Data-Specs) for what the unit of your key is.
* `device_class` - the [Home Assistant device class](https://www.home-assistant.io/integrations/sensor/).  They don't have them for all types (like wind), so you can either use `none` or leave it off.
* `mqtt_name` - the name of the key sent to Home Assistant via MQTT.  This will be the name of your entity.  Should be unique, but otherwise can be anything you want.

