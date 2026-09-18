import network
import time

SSID = "Vijay"
PASSWORD = "201020102"

wifi = network.WLAN(network.STA_IF)
wifi.active(True)

print("Connecting to Wifi...")

wifi.connect(SSID, PASSWORD)

while not wifi.isconnected():
	time.sleep(0.5)
	print(".", end="")

print()
print("Connected")
print("IP:", wifi.ifconfig()[0])

