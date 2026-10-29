# FuelWatch

A macOS menu bar app that watches fuel prices around your town in France.

- Shows the cheapest price of your chosen fuel in the menu bar.
- Per fuel (Gazole, SP95, E10, SP98, E85, GPLc): cheapest price, change since yesterday, area average, a 30-day trend and the 3 cheapest stations (click one to open it in Maps).
- Notifications when the cheapest price drops, or goes below an alert price you set per fuel.
- Optionally a message on your iPhone through [ntfy](https://ntfy.sh) whenever the cheapest price of a fuel goes down (alert prices only notify the Mac): set a server and topic under Settings → iPhone and subscribe to that topic in the ntfy app. Tapping an alert opens the station in Maps.
- Checks every 30 minutes to 6 hours; optional launch at login.

## Data

- Prices: the government open data feed "Prix des carburants en France, flux instantané v2" on data.economie.gouv.fr (the same data as prix-carburants.gouv.fr). Prices older than 7 days and fuels a station marks as unavailable are ignored.
- Town search: api-adresse.data.gouv.fr.
- History is kept for a year in `~/Library/Containers/fr.arievanboxel.fuelwatch/Data/Library/Application Support/FuelWatch/history.json`, separately per town and radius.

## Project

Swift 6, SwiftUI `MenuBarExtra`, macOS 15+. Sandboxed with outgoing network access only. Tests use Swift Testing (`FuelWatchTests`).
