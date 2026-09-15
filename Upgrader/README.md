# WheelClick Upgrader

A small app that moves an App Store copy of WheelClick to the direct version, for free.

## What it does

1. Reads the App Store receipt inside `/Applications/WheelClick.app`.
2. Sends it with your email to wheelclick.app, which checks it with Apple's certificate and issues a license key.
3. Downloads the latest WheelClick from this repository's releases and checks that it is signed by the WheelClick developer.
4. Replaces the App Store copy with the downloaded one.
5. Opens WheelClick with the license key, so it is activated.

## What it sends

The receipt, the email, and a `source` marker saying the request came from this app, to wheelclick.app. It also downloads WheelClick.dmg from this repository's GitHub releases. Nothing else is sent.

## Why it asks for a password

App Store apps are owned by the system (root), so replacing one needs an administrator password. macOS asks for it once.

## Building

```sh
scripts/build-app.sh   # WheelClick Upgrader.app in .build/app/
swift test             # tests
```
