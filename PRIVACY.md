# Privacy

ActionFlow has no telemetry, accounts, cloud sync or remote control service. Rules run locally, and the app does not upload configurations or execution history.

## Data use

- Input Monitoring matches enabled keyboard, mouse and scroll triggers without storing raw typed text. A key press that matches an enabled single-press shortcut rule is kept from the active app; all other input is passed on unchanged.
- Application events use bundle identifiers and process information. Window and text actions use Accessibility objects; menu actions read titles needed to match the configured path.
- Configurations, backups and snapshots stay on disk and may contain text, URLs, app identifiers and scripts you provide.
- Recent execution status stays in memory. Action bodies and script output are not stored in the activity history.

URL, menu and shell actions produce the effects you configure, which may include network access and file changes. The app does not sandbox these actions.

The offline CLI reads files you specify, does not access the live configuration by default, and never executes rules. Rendering checks capture only the app's own views. Review images and configuration files before sharing private content.
