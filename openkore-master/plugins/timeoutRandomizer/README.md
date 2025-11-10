# timeoutRandomizer plugin

This plugin lets you configure random ranges for specific entries in `control/timeouts.txt` without modifying the core parser.

## Usage
1. Copy `plugins/timeoutRandomizer/timeoutRandomizer.pl` to your `plugins.txt` list so OpenKore loads it.
2. Edit `control/timeout_randomizer.txt` and add the timeouts you want to randomize. Each line should contain the timeout name followed by either a single value or a minimum and maximum value. When the `profiles` plugin is in use, the configuration is loaded from the selected profile folder (for example, `profiles/bot1/timeout_randomizer.txt`).
3. Reload the configuration (`reload timeouts`, `reload timeout_randomizer`, or restart OpenKore).

Example configuration:
```
ai_teleport 1 8
ai_attack 0.6..1.4
ai 3
```
The plugin chooses an initial random value when the timeout is first used and then rolls a new value each time the timeout finishes and the timer is restarted (either by `timeOut()` or by code that manually updates the timeout's `time` field). Successive uses of the same action (for example repeated `ai_teleport` casts) therefore receive independent randomized delays throughout the entire session.
