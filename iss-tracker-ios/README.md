# ISS Tracker – iOS App

A native iOS app that tracks the International Space Station in real time and sends local push notifications **24 hours**, **1 hour**, and **5 minutes** before it passes overhead.

## Features

- **Live map** – ISS position updates every 5 seconds on a MapKit map with its ground track
- **Pass predictions** – computes upcoming visible passes for the next 7 days using a built-in SGP4 orbit propagator (no API key required)
- **Rich pass details** – start/peak/end time, max elevation, compass directions, duration, quality rating
- **Local notifications** – fires at T-24 h, T-1 h, and T-5 min before each pass, even with the app closed
- **Auto TLE refresh** – fetches current orbital elements every hour from wheretheiss.at

## Requirements

- Xcode 15+
- iOS 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the `.xcodeproj`

## Build & Run

```bash
# Install XcodeGen (one-time)
brew install xcodegen

# Generate the Xcode project
cd iss-tracker-ios
xcodegen generate

# Open in Xcode
open ISSTracker.xcodeproj
```

Then select a simulator or device, press **Run** (`⌘R`).

## Usage

1. Open the app → it immediately shows the ISS live on the map.
2. Tap **Settings** → **Use My Location** (or enter coordinates manually).
3. Tap **Enable Pass Notifications** → allow notification permission.
4. Switch to the **Passes** tab to see upcoming overhead passes.

Notifications arrive automatically at 24 h, 1 h, and 5 min before each pass, even when the app is in the background or closed.

## How It Works

- **Orbital data** – TLE (Two-Line Element) fetched from `wheretheiss.at`
- **Orbit propagation** – built-in Swift port of the SGP4 algorithm (Vallado / satellite.js)
- **Pass computation** – 10-second step integration for 7 days, minimum 10° elevation
- **Notifications** – `UNUserNotificationCenter` local triggers, rescheduled on every app launch

## Data Sources

- Live position & TLE: [wheretheiss.at](https://wheretheiss.at) (free, no key needed)
