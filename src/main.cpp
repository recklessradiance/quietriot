#include <ESP8266WiFi.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <I2S.h>

#define WIFI_SSID "YOUR_WIFI_SSID"
#define WIFI_PASS "YOUR_WIFI_PASSWORD"

#define SAMPLE_RATE 16000
#define PCM_CHUNK 1024

I2SClass mic(false, true, true);

Adafruit_SSD1306 oled(128, 64, &Wire, -1);

WiFiServer server(80);

int16_t rawFrames[2 * PCM_CHUNK];
int16_t pcmOut[PCM_CHUNK];


void showStatus(bool streaming) {

    String ip = WiFi.localIP().toString();

    oled.clearDisplay();
    oled.setTextSize(1);
    oled.setTextColor(SSD1306_WHITE);
    oled.setCursor(24, 0);
    oled.print("QUIETRIOT");
    oled.setCursor(0, 16);
    oled.print(streaming ? "* ONLINE" : "ONLINE");
    oled.setCursor(0, 32);
    oled.print(ip);
    oled.setCursor(0, 48);
    oled.print(streaming ? "STREAM: ON" : "STREAM: --");
    oled.display();
}


void sendWavHeader(WiFiClient &client) {

    uint32_t sr = SAMPLE_RATE;
    uint32_t dataLen = 0x7FFF0000;
    uint32_t riffLen = dataLen - 36;
    uint32_t byteRate = SAMPLE_RATE * 2;

    uint8_t h[44] = {
        'R','I','F','F', 0,0,0,0,
        'W','A','V','E',
        'f','m','t',' ',
        16,0,0,0,
        1,0,
        1,0,
        0,0,0,0,
        0,0,0,0,
        2,0,
        16,0,
        'd','a','t','a',
        0,0,0,0
    };

    h[4]  = riffLen & 0xff;
    h[5]  = (riffLen >> 8) & 0xff;
    h[6]  = (riffLen >> 16) & 0xff;
    h[7]  = (riffLen >> 24) & 0xff;

    h[24] = sr & 0xff;
    h[25] = (sr >> 8) & 0xff;
    h[26] = (sr >> 16) & 0xff;
    h[27] = (sr >> 24) & 0xff;

    h[28] = byteRate & 0xff;
    h[29] = (byteRate >> 8) & 0xff;
    h[30] = (byteRate >> 16) & 0xff;
    h[31] = (byteRate >> 24) & 0xff;

    h[40] = dataLen & 0xff;
    h[41] = (dataLen >> 8) & 0xff;
    h[42] = (dataLen >> 16) & 0xff;
    h[43] = (dataLen >> 24) & 0xff;

    client.write(h, 44);
}


void handleStream(WiFiClient &client) {

    client.setNoDelay(true);

    client.println("HTTP/1.1 200 OK");
    client.println("Content-Type: audio/wav");
    client.println("Connection: close");
    client.println();
    client.flush();

    if (!mic.begin(I2S_PHILIPS_MODE, SAMPLE_RATE, 16)) {
        Serial.println("I2S begin failed");
        client.stop();
        showStatus(false);
        return;
    }

    sendWavHeader(client);
    client.flush();

    Serial.println("Audio stream started");
    showStatus(true);

    size_t pcmCount = 0;

    while (client.connected()) {

        int n = mic.read(rawFrames, 2 * PCM_CHUNK);

        if (n <= 0) {
            delay(1);
            continue;
        }

        int frames = n / 2;

        for (int i = 0; i < frames; i++) {
            pcmOut[pcmCount++] = rawFrames[2 * i];
        }

        if (pcmCount >= PCM_CHUNK) {
            size_t bytes = pcmCount * 2;
            size_t sent = client.write((const uint8_t *)pcmOut, bytes);
            if (sent != bytes) {
                break;
            }
            pcmCount = 0;
        }
    }

    mic.end();

    Serial.println("Audio stream ended");
    showStatus(false);

    client.stop();
}


const char PAGE_BODY[] PROGMEM = R"html(<!DOCTYPE html>
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
    INMP441 LIVE
</div>

<div class="btns">

    <button id="power" class="active">
        Stop
    </button>

</div>

<div id="hint">
    QuietRiot ESP8266 &middot;
    INMP441 mic stream
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
            sampleRate: 16000
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

            const n = d.length - (d.length % 2);

            if (n === 0) {
                continue;
            }

            const buf = ctx.createBuffer(1, n / 2, ctx.sampleRate);

            const ch = buf.getChannelData(0);

            for (let i = 0, j = 0; i < n; i += 2, j++) {
                ch[j] = (((d[i] | (d[i + 1] << 8)) << 16) >> 16) / 32768;
            }

            if (nextTime === 0) {
                nextTime = ctx.currentTime + 0.15;
            }

            const src = ctx.createBufferSource();

            src.buffer = buf;
            src.connect(ctx.destination);
            src.start(nextTime);

            nextTime += (n / 2) / ctx.sampleRate;

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
)html";


void handlePage(WiFiClient &client, const String &ip) {

    String header = String("HTTP/1.1 200 OK\r\n"
                           "Content-Type: text/html\r\n"
                           "Connection: close\r\n\r\n");

    String body;
    body.reserve(3200);
    body += FPSTR(PAGE_BODY);

    body.replace("%s", ip);

    client.print(header);
    client.print(body);
    client.flush();
}


void connectWifi() {

    WiFi.mode(WIFI_STA);
    WiFi.begin(WIFI_SSID, WIFI_PASS);

    Serial.print("Connecting to WiFi");
    while (WiFi.status() != WL_CONNECTED) {
        delay(500);
        Serial.print(".");
    }

    Serial.println();
    Serial.print("Connected, IP: ");
    Serial.println(WiFi.localIP());
}


void setup() {

    Serial.begin(115200);

    Wire.begin(4, 5);

    if (!oled.begin(SSD1306_SWITCHCAPVCC, 0x3C)) {
        Serial.println("OLED init failed");
    }

    connectWifi();
    showStatus(false);

    server.begin();
    server.setNoDelay(true);

    Serial.println("QuietRiot ready");
}


void loop() {

    WiFiClient client = server.accept();

    if (!client) {
        return;
    }

    Serial.printf("HTTP client: %s\n",
                  client.remoteIP().toString().c_str());

    String request = "";
    uint32_t t0 = millis();

    while (client.connected()) {
        if (client.available()) {
            request += (char)client.read();
            if (request.endsWith("\r\n\r\n")) {
                break;
            }
        }
        if (millis() - t0 > 2000) {
            break;
        }
    }

    if (request.indexOf("/stream") != -1) {
        handleStream(client);
    } else {
        handlePage(client, WiFi.localIP().toString());
        client.stop();
    }
}
