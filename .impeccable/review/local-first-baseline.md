# Local-first Mac improvements baseline

Captured from the currently installed application before production changes.

## Installed artifact

- Application: `/Applications/Murmure.app`
- Version: `0.1.12`
- Build: `12`
- Binary SHA-256: `773927fb82154acd21059577886d8ae436fd2226435e8438d99e52463e621e5d`
- Appearance captured: dark
- Light appearance: pending because changing the system appearance is outside this non-mutating baseline pass

## Locked surfaces

| Surface | Evidence | Baseline observations |
| --- | --- | --- |
| Main window and history | `local-first-baseline/main-window-dark.jpeg` | Home summary, push-to-talk control, recent-history rows, and recorder styling are the locked visual baseline. |
| Settings | `local-first-baseline/settings-dark.jpeg` | Existing section order, field-recorder styling, engine selector, compare toggle, cleanup settings, permissions, and storage status are locked. |
| Engine comparison | Pending | The installed scene is discoverable as `Engine comparison` in the Window menu. Screenshot capture is pending because the automation surface did not activate the menu item reliably. |
| Light appearance | Pending | Must be captured without changing the user's global appearance setting, or with explicit permission for that temporary system change. |

## Runtime observations

- Microphone permission: granted
- Accessibility permission: granted
- External storage: ready
- Selected engine: Apple streaming
- Compare both local engines: off
- Cleanup: on
- Smart cleanup: off
- Start and finish sounds: on
- Push-to-talk key: `fn`

## Visual-change gate

The existing shell remains locked. Approved work may add the explicitly requested controls and recovery states, but must reuse the design-system tokens and must not restyle unrelated layout, spacing, color, typography, imagery, or animation.
