import network
import time
import socket
import struct

from machine import Pin, I2C, ADC
import ssd1306


# -----------------------------
# Configuration
# -----------------------------

SSID = "YOUR_WIFI_SSID"
PASSWORD = "YOUR_WIFI_PASSWORD"

SCL_PIN = 5
SDA_PIN = 4

OLED_ADDR = 0x3C

SAMPLE_RATE = 4500
BLOCK = 512


# -----------------------------
# OLED
# -----------------------------

def init_display():
    i2c = I2C(
        scl=Pin(SCL_PIN),
        sda=Pin(SDA_PIN)
    )

    print("I2C devices:", i2c.scan())

    oled = ssd1306.SSD1306_I2C(
        128,
        64,
        i2c,
        addr=OLED_ADDR
    )

    return oled


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
        oled.text(
            "BATTERY: %d%%" % battery,
            0,
            56
        )

    oled.show()


# -----------------------------
# Wi-Fi
# -----------------------------

def connect_wifi(oled):
    wifi = network.WLAN(network.STA_IF)

    wifi.active(True)

    if wifi.isconnected():
        return wifi

    print("Connecting to Wifi...")

    wifi.connect(
        SSID,
        PASSWORD
    )

    while not wifi.isconnected():
        time.sleep_ms(500)
        print(".", end="")

    print()
    print("Connected")
    print("IP:", wifi.ifconfig()[0])

    return wifi


# -----------------------------
# Microphone
# -----------------------------

def init_microphone():
    adc = ADC(0)

    print("Audio ADC ready")
    print("Sample rate: %d Hz" % SAMPLE_RATE)

    return adc


# -----------------------------
# Audio streaming
# -----------------------------

def sample_block(adc, buf):
    read = adc.read
    n = len(buf)
    for i in range(n):
        buf[i] = read() >> 2


def wav_header(total):
    return struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF",
        36 + total,
        b"WAVE",
        b"fmt ",
        16,
        1,
        1,
        SAMPLE_RATE,
        SAMPLE_RATE,
        1,
        8,
        b"data",
        total
    )


def handle_stream(client, adc, oled, wifi):

    buf = bytearray(BLOCK)

    try:

        client.setsockopt(
            socket.IPPROTO_TCP,
            socket.TCP_NODELAY,
            1
        )

        client.sendall(
            "HTTP/1.1 200 OK\r\n"
            "Content-Type: audio/wav\r\n"
            "Connection: close\r\n"
            "\r\n"
        )

        client.sendall(wav_header(0x7FFF0000))

        show_status(oled, wifi, listeners=1, battery=None)

        print("Audio stream started")

        while True:
            sample_block(adc, buf)
            client.sendall(buf)

    except OSError as e:
        print("Audio stream ended:", e)

    finally:
        show_status(oled, wifi, listeners=0, battery=None)


# -----------------------------
# Web page
# -----------------------------

def web_page(ip):
    return """<!DOCTYPE html>
<html>

<head>
<meta charset="utf-8">
<meta name="viewport"
      content="width=device-width, initial-scale=1">

<title>quietriot</title>

<style>

body {
    background:#111;
    color:#eee;
    font-family:Helvetica,Arial,sans-serif;
    margin:0;
    text-align:center;
}

h1 {
    font-size:18px;
    font-weight:normal;
    margin:10px 0 4px;
}

#status {
    font-size:12px;
    color:#8f8;
    margin-bottom:8px;
    min-height:16px;
}

#device {
    width:100%%;
    max-width:640px;
    height:360px;
    margin:auto;
    background:#000;

    display:flex;
    align-items:center;
    justify-content:center;

    color:#555;
    font-size:13px;
}

.btns {
    margin:12px auto 4px;
}

button {
    font-size:16px;
    padding:10px 26px;
    margin:0 6px;

    border:1px solid #555;
    border-radius:6px;

    background:#333;
    color:#eee;
}

button.active {
    background:#4a7;
    border-color:#4a7;
    color:#fff;
}

#err {
    color:#f88;
    font-size:12px;
}

#hint {
    color:#888;
    font-size:11px;
    margin-top:6px;
}

</style>
</head>

<body>

<h1>quietriot &middot; live</h1>

<div id="status">
    connected &middot; %s
</div>

<div id="device">
    AUDIO READY
</div>

<div class="btns">

    <button id="power" class="active">
        Stop
    </button>

</div>

<div id="hint">
    QuietRiot ESP8266 &middot;
    live mic stream
</div>

<div id="err"></div>


<script>

const status =
    document.getElementById("status");

const err =
    document.getElementById("err");

const power =
    document.getElementById("power");

let ctx = null;
let reader = null;
let ctrl = null;
let running = false;


function setRunning(on, text) {

    running = on;

    power.textContent = on ? "Stop" : "Start";

    if (on) {
        power.classList.add("active");
    } else {
        power.classList.remove("active");
    }

    status.textContent = text;
}


function stopStream() {

    running = false;

    if (ctrl) {
        ctrl.abort();
        ctrl = null;
    }

    reader = null;

    if (ctx) {
        ctx.close();
        ctx = null;
    }

    setRunning(false, "stopped");
}


power.onclick = function() {

    if (running) {
        stopStream();
        return;
    }

    startStream();
};


async function startStream() {

    status.textContent = "connecting...";
    err.textContent = "";

    try {

        ctx = new AudioContext({
            sampleRate: 4500
        });

        ctrl = new AbortController();

        const res = await fetch("/stream", {
            signal: ctrl.signal
        });

        if (!res.ok) {
            throw new Error("http " + res.status);
        }

        reader = res.body.getReader();

        let nextTime = 0;
        let skipped = 0;

        while (reader) {

            const r = await reader.read();

            if (r.done) {
                break;
            }

            let d = r.value;

            if (skipped < 44) {
                const cut = 44 - skipped;
                d = d.subarray(cut);
                skipped = 44;
            }

            if (d.length === 0) {
                continue;
            }

            const n = d.length;

            const buf = ctx.createBuffer(1, n, ctx.sampleRate);

            const ch = buf.getChannelData(0);

            for (let i = 0; i < n; i++) {
                ch[i] = (d[i] - 128) / 128;
            }

            if (nextTime === 0) {
                nextTime = ctx.currentTime + 0.15;
            }

            const src = ctx.createBufferSource();

            src.buffer = buf;
            src.connect(ctx.destination);
            src.start(nextTime);

            nextTime += n / ctx.sampleRate;

            if (!running) {
                setRunning(true, "streaming");
            }
        }

        if (running) {
            stopStream();
        }

    } catch (e) {

        if (running || ctx) {
            stopStream();
        }

        err.textContent = "stream failed: " + e.message;
    }
}

</script>

</body>
</html>
""" % ip


# -----------------------------
# HTTP server
# -----------------------------

def start_web_server():

    addr = socket.getaddrinfo(
        "0.0.0.0",
        80
    )[0][-1]

    server = socket.socket()

    server.setsockopt(
        socket.SOL_SOCKET,
        socket.SO_REUSEADDR,
        1
    )

    server.bind(addr)

    server.listen(1)

    print("Web server started")

    return server


def handle_request(server, wifi, oled, adc):

    client, addr = server.accept()

    print("HTTP client:", addr)

    try:

        request = client.recv(1024)

        if not request:
            return

        line = request.split(b"\r\n")[0]
        path = line.split(b" ")[1]

        if path.startswith(b"/stream"):
            handle_stream(client, adc, oled, wifi)
            return

        response = web_page(
            wifi.ifconfig()[0]
        )

        header = (
            "HTTP/1.1 200 OK\r\n"
            "Content-Type: text/html\r\n"
            "Content-Length: %d\r\n"
            "Connection: close\r\n"
            "\r\n"
        ) % len(response)

        client.sendall(header)
        client.sendall(response)

    except Exception as e:

        print("HTTP error:", e)

    finally:

        client.close()


# -----------------------------
# Main
# -----------------------------

def main():

    oled = init_display()

    wifi = connect_wifi(oled)

    adc = init_microphone()

    show_status(
        oled,
        wifi,
        listeners=0,
        battery=None
    )

    server = start_web_server()

    ip = wifi.ifconfig()[0]

    print("QuietRiot ready")
    print("IP:", ip)
    print("Open: http://%s" % ip)

    while True:

        handle_request(
            server,
            wifi,
            oled,
            adc
        )


main()
