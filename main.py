import network
import time
from machine import Pin, I2C
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
    oled.text("QUIETRIOT", 0, 0)
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
    oled.text("QUIETRIOT", 0, 0)
    oled.text("WIFI:", 0, 16)
    oled.text("CONNECTING", 0, 32)
    oled.show()

    print("Connecting to Wifi...")

    wifi.connect(ssid, password)

    while not wifi.isconnected():
        time.sleep(0.5)
        print(".", end="")

    print()
    print("Connected")
    print("IP:", wifi.ifconfig()[0])

    return wifi


# -----------------------------
# Status display
# -----------------------------

def show_status(oled, wifi, listeners=0, battery=None):
    ip = wifi.ifconfig()[0]

    oled.fill(0)

    oled.text("QUIETRIOT", 0, 0)
    oled.text("* ONLINE", 0, 16)
    oled.text(ip, 0, 32)
    oled.text("LISTENERS: %d" % listeners, 0, 48)

    if battery is None:
        oled.text("BATTERY: --%", 0, 56)
    else:
        oled.text("BATTERY: %d%%" % battery, 0, 56)

    oled.show()


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

    show_status(
        oled,
        wifi,
        listeners=0,
        battery=None
    )

    return wifi, oled


