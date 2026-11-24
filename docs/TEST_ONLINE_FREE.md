# Stage 1 — free online test (Mac mini + Cloudflare Quick Tunnel)

Goal: phones outside your home can use the app, for $0, while you test with yourself and 1–2 friends.
Not for real clients: the Mac must stay on, and the tunnel address changes every time it restarts.

1. Mac: `brew install cloudflared` (or download it from Cloudflare's site).
2. Start the database and server as usual: `docker compose up -d`, `cd backend && npm run dev`.
3. New terminal: `cloudflared tunnel --url http://localhost:3000` → it prints `https://<random>.trycloudflare.com`.
4. Phone browser: open `https://<random>.trycloudflare.com/health` → `{"ok":true,...}`.
5. Android release builds need the internet permission. In `mobile/android/app/src/main/AndroidManifest.xml`, above `<application`:
   `<uses-permission android:name="android.permission.INTERNET"/>`
6. Build: `flutter build apk --release --flavor client` and `flutter build apk --release --flavor admin`
   (files in `mobile/build/app/outputs/flutter-apk/`). Send the client APK by Telegram/Viber; allow "install unknown apps".
7. In the app: login screen → server icon (top left) → paste the tunnel address → Test → Save.
   When the tunnel restarts with a new address: ⋮ menu → Server → paste the new one. No new APK needed.
8. Keep the Mac awake while testing: `caffeinate -s` in a terminal (Ctrl+C to stop), or Energy settings.

Safety while the server is public: use a strong Admin password, stop the tunnel (Ctrl+C) when you are not testing.
