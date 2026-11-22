# Wi-Fi Heatmap (iPhone app)

Walk around with your iPhone, tap where you're standing on a floor plan, and the app measures
Wi-Fi download speed and latency there, then paints a red→green heatmap.

> iOS doesn't let apps read Wi-Fi signal strength (dBm), so the app measures real-world
> speed and latency instead. You can type in a dBm reading per point if you have one.

---

## Getting it onto your iPhone from a Windows PC

You'll need: a free **GitHub** account, your **Apple ID**, your iPhone and its USB cable.

### Part 1 – Let GitHub build the app (about 15 minutes, mostly waiting)

1. Unzip `WiFiHeatmap.zip` somewhere easy, like your Desktop.
2. Sign in at **github.com** → click **+** (top right) → **New repository**.
   Name it `WiFiHeatmap`, choose **Public** (unlimited free build time), and click **Create repository**.
3. On the new repo page, click the **uploading an existing file** link.
4. Open the unzipped `WiFiHeatmap` folder in File Explorer, select **everything inside it**
   (including the `.github` folder), and drag it all onto the GitHub page.
   Wait for the uploads to finish, then click **Commit changes**.
5. Click the **Actions** tab. A run called "Build iPhone app" starts automatically
   (if GitHub asks you to enable workflows, click the green button, then **Run workflow**).
6. Wait for a green ✓ (about 5–10 minutes). Click the run, scroll to **Artifacts**,
   and download **WiFiHeatmap-ipa**. Unzip it to get `WiFiHeatmap.ipa`.

   If you get a red ✗ instead, click into the failed step and copy the error lines to Claude to fix.

### Part 2 – Install it with Sideloadly (one-time setup)

1. Install **iTunes** and **iCloud** from Apple's website — **not** the Microsoft Store versions
   (uninstall those first if you have them):
   - iTunes: https://www.apple.com/itunes/download/win64
2. Install **Sideloadly** from https://sideloadly.io
3. Plug in your iPhone, unlock it, and tap **Trust** when it asks about this computer.
4. Open Sideloadly → drag `WiFiHeatmap.ipa` onto it → type your Apple ID → **Start**.
   Enter your Apple ID password and the 2-factor code when asked.
5. On the iPhone:
   - **Settings → Privacy & Security → Developer Mode** → turn on, and restart when prompted.
   - **Settings → General → VPN & Device Management** → tap your Apple ID → **Trust**.
6. Open **Wi-Fi Heatmap** from your home screen.

**Every 7 days** the app stops opening (an Apple rule for free accounts). Just plug in and run
Sideloadly again with the same `.ipa` — your surveys are kept.

---

## Using the app

1. **+** → name the survey, optionally pick or photograph a floor plan (blank grid otherwise).
2. Stand somewhere, tap that spot on the map → **Measure here** (5–10 s).
3. Repeat around your home. Switch between Download / Latency / RSSI at the top.
4. Tap a dot to see details, add a dBm reading, or delete it.
5. Share the heatmap image or a CSV from the share button.

Measurements are only saved while the phone is on Wi-Fi.
