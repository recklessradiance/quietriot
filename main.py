import network
import time
from machine import Pin, I2C, ADC
import ssd1306


# -----------------------------
# OLED
# -----------------------------

def init_display():
    i2c = I2C(
        scl=Pin(5),
        sda=Pin(4)
    )

    oled = ssd1306.SSD1306_I2C(
        128,
        64,
        i2c,
        addr=0x3C
    )

    oled.fill(0)
    oled.text("QUIETRIOT", 24, 0)
    oled.text("STARTING...", 0, 16)
    oled.show()

    return oled


# -----------------------------
# Wi-Fi
# -----------------------------

def connect_wifi(ssid, password, oled):
    wifi = network.WLAN(network.STA_IF)
    wifi.active(True)

    oled.fill(0)
    oled.text("QUIETRIOT", 24, 0)
    oled.text("WIFI:", 0, 16)
    oled.text("CONNECTING", 0, 32)
    oled.show()

    print("Connecting to Wifi...")

    wifi.connect(ssid, password)

    while not wifi.isconnected():
        time.sleep_ms(500)
        print(".", end="")

    ip = wifi.ifconfig()[0]

    print()
    print("Connected")
    print("IP:", ip)

    return wifi


# -----------------------------
# Microphone
# -----------------------------

def init_microphone():
    adc = ADC(0)
    return adc


# -----------------------------
# Status display
# -----------------------------

def show_status(oled, wifi, listeners=0, battery=None):
    ip = wifi.ifconfig()[0]

    oled.fill(0)

    oled.text("QUIETRIOT", 24, 0)
    oled.text("* ONLINE", 0, 16)
    oled.text(ip, 0, 32)
    oled.text("LISTENERS: %d" % listeners, 0, 48)

    if battery is None:
        oled.text("BATTERY: --%", 0, 56)
    else:
        oled.text("BATTERY: %d%%" % battery, 0, 56)

    oled.show()


# -----------------------------
# Audio sampling
# -----------------------------

def sample_audio(adc, duration_ms=1000, sample_rate=8000):
    sample_count = sample_rate * duration_ms // 1000

    samples = bytearray(sample_count)

    interval_us = 1000000 // sample_rate

    for i in range(sample_count):
        start = time.ticks_us()

        value = adc.read()

        # Convert 10-bit ADC value to 8-bit value.
        samples[i] = value >> 2

        while time.ticks_diff(
            time.ticks_us(),
            start
        ) < interval_us:
            pass

    return samples


# -----------------------------
# Main
# -----------------------------

def main(ssid, password):
    oled = init_display()

    wifi = connect_wifi(
        ssid,
        password,
        oled
    )

    adc = init_microphone()

    show_status(
        oled,
        wifi,
        listeners=0,
        battery=None
    )

    print("QuietRiot ready")
    print("IP:", wifi.ifconfig()[0])
    print("Audio ADC ready")
    print("Sample rate: 8000 Hz")

    return wifi, oled, adc


