# Production: separate Client and Admin apps

One codebase, two apps:

| | Client app | Admin app |
|---|---|---|
| Who | your clients (dealers) | only you |
| Login | email + 6-digit code | phone + password |
| Android id | `com.yourname.ledger_app.client` | `com.yourname.ledger_app.admin` |
| Name on phone | 2D Ledger | 2D Ledger Admin |
| Distribute | Play Store (or APK link) | install the APK on your own phone; never publish |

Both apps talk to the same server. The server still decides who is Admin; the client app simply has no Admin login (`lib/config.dart`, `appMode`).

## Step 1 — Put the server online (needed before any client can use the app)

1. A small Linux VPS (1–2 GB RAM) + a domain, e.g. `api.example.com`.
2. Install Docker; run PostgreSQL (`docker compose up -d`) and the backend (`npm ci && npm run build && npm start`, or a Docker image).
3. HTTPS in front (Caddy or nginx + Let's Encrypt). The apps must use `https://`.
4. `backend/.env` on the server: a new long `JWT_SECRET`, a strong DB password, `NODE_ENV=production`, `TRUST_PROXY` set for the proxy.
5. `npm run migrate`, then `npm run create-admin` (or `reset-admin-password`).
6. Daily database backups (`pg_dump`) copied off the server.

## Step 2 — Android flavors (one time)

In `mobile/android/app/build.gradle.kts`, inside `android { ... }`:

```kotlin
    flavorDimensions += "app"
    productFlavors {
        create("client") {
            dimension = "app"
            applicationIdSuffix = ".client"
            resValue("string", "app_name", "2D Ledger")
        }
        create("admin") {
            dimension = "app"
            applicationIdSuffix = ".admin"
            resValue("string", "app_name", "2D Ledger Admin")
        }
    }
```

In `mobile/android/app/src/main/AndroidManifest.xml` change the label to `android:label="@string/app_name"`.
Remove `android:usesCleartextTraffic="true"` for release (production uses HTTPS).

The Dart code reads the flavor (`appFlavor`), so the client build can never show the Admin login.

## Step 3 — Build

```bash
cd mobile
# Client app (give this to clients / upload to Play Store)
flutter build appbundle --release --flavor client --dart-define=API_URL=https://api.example.com
flutter build apk       --release --flavor client --dart-define=API_URL=https://api.example.com
# Admin app (only for you)
flutter build apk --release --flavor admin --dart-define=API_URL=https://api.example.com
# Development (both logins, local server)
flutter run --flavor client          # or --flavor admin; once flavors exist, flutter run needs --flavor
```

Always pass `API_URL` for release builds — without it the app points at the development address.

## Step 4 — Signing and store

* Create an upload keystore once (`keytool -genkey ...`), keep it and its passwords safe; set `signingConfigs` for release.
* Play Console account (one-time fee). Upload the **client** app bundle only.
* iPhone clients need an Apple Developer account (yearly) and TestFlight/App Store; iOS flavors are set up in Xcode schemes.
