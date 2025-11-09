# timeoutRandomizer plugin

This plugin lets you configure random ranges for specific entries in `control/timeouts.txt` without modifying the core parser.

## Usage
1. Copy `plugins/timeoutRandomizer/timeoutRandomizer.pl` to your `plugins.txt` list so OpenKore loads it.
2. Edit `control/timeout_randomizer.txt` and add the timeouts you want to randomize. Each line should contain the timeout name followed by either a single value or a minimum and maximum value.
3. Reload the configuration (`reload timeouts`, `reload timeout_randomizer`, or restart OpenKore).

Example configuration:
```
ai_teleport 1 8
ai_attack 0.6..1.4
ai 3
```
The plugin will choose a fresh random value within the specified range every time the AI resets the corresponding timeout.
