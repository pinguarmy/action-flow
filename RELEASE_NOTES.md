# ActionFlow 0.1.0 Alpha 7

A native macOS app for rule-based automation and action chains.

- Shortcut, mouse, scroll, application-event and timer triggers.
- Window layouts, text, menu commands, apps, links, notifications and optional scripts.
- Rule templates, previews, execution progress, filters, backups and snapshot recovery.
- English and Simplified Chinese interfaces.
- An offline CLI for inspecting configuration files.

Requires macOS 14+. Apple Silicon and Intel packages are available. Extract the ZIP or open the DMG, then drag `ActionFlow.app` into Applications. Global automation and scripts start off; grant system permissions yourself as needed.

This is an ad-hoc-signed Alpha release, without Apple notarization. The in-app gesture lab does not provide global multi-finger gesture support.

## Unreleased

- Edits save automatically and are flushed when the app quits. The editor shows whether changes are saved.
- An unfinished draft no longer raises an error or pauses automation; Save lists what to fix.
- Menu commands are edited one title per row. The JSON form remains available.
- Validation errors, rule summaries, conflict warnings, status and activity messages follow the interface language.
- Single-press shortcut rules keep their key press from reaching the active app. This needs Accessibility permission and can be turned off per rule.
- Input observation is limited to the input kinds enabled rules use.
- The minimum window size is 960 × 620.
- Window layouts no longer report a failure when an app such as Terminal rounds or limits the requested size.
- Search matches the trigger and action names shown in the interface language. Rules can be reordered by dragging.
- F13–F20 and keypad keys have readable names.
- The recovery backup keeps an earlier version instead of the last autosave: it is refreshed at most every 10 minutes and before imports and templates.
- Rules can be switched on and off from the rule list.
