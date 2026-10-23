# Security

ActionFlow executes desktop actions from rules you enable, using your user account and granted system permissions. It is not an execution sandbox.

## Permissions and defaults

- Global automation and shell scripts start off. Examples and imported rules start disabled.
- Input Monitoring, Accessibility, notifications and login startup require your approval.
- Input observation is passive. It does not intercept or store text typed in other apps.
- There is no telemetry, remote configuration endpoint, network listener or automatic permission grant.

## Rules and actions

Enable only rules you understand. Shell scripts can read, modify or delete files; links and scripts may access the network; menu commands can invoke destructive operations. Importing a configuration is not a security review.

The app checks permissions, session state and target identity before execution, and continues checking focus during sensitive actions. Sleep and session changes pause automation until you resume it. These checks cannot make event delivery fully atomic or undo earlier effects.

Pause and stop controls are available in the menu bar. Scripts have time and process-group limits, but a malicious script may launch other processes. Do not treat these limits as isolation.

## Configuration

Configurations and backups use private file permissions, temporary files and atomic replacement. A cooperative writer lock prevents app instances from overwriting each other, but does not constrain external editors. Configurations and exports may contain private text, app identifiers, URLs or code.

## Reporting

Use GitHub's private vulnerability reporting feature. Do not post passwords, tokens, private rules, full configurations or raw desktop screenshots in public issues.

Release packages are ad-hoc signed and not Apple-notarized. Rebuilding or changing the app identifier may require permissions to be granted again. Do not disable system security protections to run the app.
