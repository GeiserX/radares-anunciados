# Privacy policy: Radares Anunciados

Radares Anunciados warns you before announced speed radars in Spain. It has no account, no server, no ads, no analytics and no tracking. The app never uploads your location.

## What the app uses, and why

- **Location.** The app uses your location to measure the distance and direction to the next announced radar. With "Always" permission it wakes up when you start moving (through Apple's significant-change and region services) and uses GPS only while you drive. The position is used on the phone and the app never uploads it.
- **Motion.** With your permission, the app asks Core Motion whether you are in a car, so it does not use GPS when you are walking. The answer stays on the phone.
- **Notifications.** The app posts local notifications for warnings and, at most once a day, a notice when something stops it from warning. They are created on the phone; there are no push notifications.

## What the app downloads

The radar list, a public file at https://geiserx.github.io/radares-anunciados-ha/feed.geojson, about every 6 hours. The request is a plain download with no identifier, no location and no account; like any web request it reaches the hosting provider (GitHub Pages) with your IP address.

## What stays on your iPhone

- The radar list and the time it was downloaded.
- A log of the app's own events, so the Estado screen can tell whether the warning chain works. Alert rows in it include the position where each warning fired. The app never uploads the log. You can export it yourself from Ajustes; the exported file contains those alert positions, so they leave the phone only if you share it. Deleting the app deletes the log.
- Your settings (voice, warnings on or off).

The radar list and the log are marked to be left out of iCloud backups; the app can download the list again.

## What we do not do

- No account, sign-in or registration.
- No advertising, no analytics, no crash-reporting service, no tracking across apps or websites.
- No sale or sharing of data with anyone.

## Contact

Open an issue at https://github.com/GeiserX/radares-anunciados/issues, or report privately through https://github.com/GeiserX/radares-anunciados/security/advisories/new.

Last updated: October 2026.
