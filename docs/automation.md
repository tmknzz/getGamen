# CLI and MCP

The app bundle contains the GUI and a separate automation helper:

```sh
/Applications/getGamen.app/Contents/MacOS/getGamen --help
```

No arguments or single-dash AppKit arguments (for example `-AppleLanguages`)
launch the GUI; `-h` shows help. Any first argument starting with a single dash
(except `-h`), including typos such as `-v`, opens the GUI instead of failing.
Use `--version` and `--help` for commands.
A command runs independently of any open GUI
windows. Before initializing AppKit, commands replace the launcher process with
`Contents/Helpers/GetGamenAutomation.app/Contents/MacOS/getGamenAutomation`.
The helper has its own bundle ID (`com.tmknzz.getGamen.automation`) and is
background-only, so Launch Services can still launch and reopen the GUI while
MCP is connected. The public command path and MCP configuration stay the same.
Automation does not modify the GUI library, preferences or unsaved
editor documents. It uses the same image decoder, renderer and encoder.

## CLI

To call `getGamen` from PATH (handy for agents that use the shell), create a
symlink and add `~/.local/bin` to PATH for zsh:

```sh
mkdir -p ~/.local/bin
ln -sf /Applications/getGamen.app/Contents/MacOS/getGamen ~/.local/bin/getGamen
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
export PATH="$HOME/.local/bin:$PATH"
```

The launcher re-launches itself from the real app location, so both the GUI
and commands work through the link. A copy or hard link of the executable in
`~/.local/bin` does not work: it must be a symbolic link, because the launcher
locates its helper and app bundle from the link target.
The launcher sets `GETGAMEN_RELAUNCHED` internally for this one-time relaunch.
Callers should not set it; if it is set, the relaunch is skipped.

For convenience in a shell session:

```sh
GETGAMEN=/Applications/getGamen.app/Contents/MacOS/getGamen
"$GETGAMEN" status
"$GETGAMEN" windows
"$GETGAMEN" displays
"$GETGAMEN" capture-window --window-id 123 --output /tmp/window.png
"$GETGAMEN" capture-region --x 0 --y 0 --width 800 --height 600 --output /tmp/region.png
"$GETGAMEN" convert --input /tmp/window.png --output /tmp/window.jpg --format jpeg --quality 0.9
"$GETGAMEN" edit --input /tmp/window.png --output /tmp/edited.png --edits '{"crop":{"x":0,"y":0,"width":200,"height":100},"objects":[{"type":"mask","bounds":{"x":10,"y":10,"width":50,"height":20}}]}'
"$GETGAMEN" tools
```

Window IDs are transient; refresh `windows` before capture. Region coordinates
are **Quartz global points, with the top-left origin of the primary display and
y increasing downward**. Use `displays` to locate screens, including those with
negative coordinates. Image edit coordinates are **original-image pixels, with
a top-left origin and y increasing downward**. The image returned by
`capture_region`/`capture_window` starts at the top-left of the requested rectangle.
The result's `width`/`height` are pixels, so convert a point offset inside the
requested rectangle to image pixels by multiplying by (result width / requested
width). When a region spans displays with different scales, the whole image uses
the largest scale. All objects are applied
in original coordinates before the crop; the optional border is drawn inside the crop edge without increasing image size.

`edit` accepts `crop`, `border` and up to 100 `objects`. Object types are `mask`,
`mosaic` and `outline`. Masks default to black; mosaics default to a block size
of 12; outlines default to black rectangles with a line width of 3. RGB colors
use `red`, `green`, `blue` numbers from 0 to 1. Use `tools` for complete schemas.
Example border: `{"width":2,"color":{"red":1,"green":0,"blue":0}}`.
Mosaics are a visual effect; use an opaque mask when content must be removed.

Every tool accepts either named flags or `--json '{...}'`; do not mix the forms.
Capture commands accept `--cursor`. Export format defaults to `png` regardless
of the filename extension. Other formats are `png8` and `jpeg`; `quality` is
valid only for JPEG. Parent directories must exist. Outputs are always new
files: existing paths, including symbolic links, are never overwritten.
Image processing is limited to 64 million pixels per automation operation.

Success returns JSON to stdout with the saved path, pixel size, byte count and
format. Failure returns JSON to stderr. Exit codes: 0 success, 1 execution or
permission failure, 2 invalid command/arguments. `help` and `--version` return
plain text. Nothing is copied to the clipboard, and images are never sent over the
network. The only network access is the license check described below.

## Screen Recording permission

`status` checks permission without opening a prompt. `authorize` explicitly
requests it. Allow the responsible app under **System Settings > Privacy &
Security > Screen Recording** (the name can vary by macOS version), then restart
the terminal or MCP host. macOS may attribute permission to the launching host;
a GUI grant does not prove that an MCP-hosted process has access. Recheck `status`
from the same host that will capture. `windows`, `displays` and capture return
`permission_required` if access is unavailable. Image conversion/editing needs
no Screen Recording permission.

## License

Manual use in the app is free. The CLI and MCP tools work for 7 days from the
first app launch or the first automation call, whichever comes first, then need
a license from Lemon Squeezy. Enter the key in getGamen Settings > ライセンス
(License). Without a license, every tool call (a CLI tool command or MCP
`tools/call`) except `status` fails with `license_required` (CLI exit 1, MCP
`isError: true`); `tools`, `authorize`, `--help`, `--version`, MCP `initialize`
and `tools/list` keep working. `status` reports the state:

```json
"license": {"state": "trial", "trial_days_remaining": 5, "purchase_url": "https://..."}
```

`state` is `trial`, `licensed` or `free`. The key is checked with the
[Lemon Squeezy License API](https://docs.lemonsqueezy.com/api/license-api).
Activation sends the key and this Mac's computer name; later checks send the key
and the activation's instance ID. After activation, a check runs when the app
launches or a tool is called, if the last successful check is more than 24 hours
old. A license stays valid for 14 days without a successful check, so short
offline periods do not interrupt work; within that time the check runs in the
background. Once the 14 days have passed, a tool call waits for the check (up to
15 seconds) before it is refused. A key that Lemon Squeezy reports as invalid
stops working from the first call after that check is recorded. After a check starts, the next one waits at least 15
minutes. The key and check times are stored in
`~/Library/Application Support/getGamen/License/license.json`, readable only by
your user.

## MCP host configuration

Add this entry to a host that supports stdio MCP servers:

```json
{
  "mcpServers": {
    "getGamen": {
      "command": "/Applications/getGamen.app/Contents/MacOS/getGamen",
      "args": ["mcp"]
    }
  }
}
```

Available tools: `status`, `displays`, `windows`, `capture_window`,
`capture_region`, `convert`, `edit`. MCP argument names use underscores. Tools
return a JSON object encoded in text content. They save images to explicit local
paths; they do not automatically attach image bytes to the conversation.

The server uses newline-delimited JSON-RPC on stdin/stdout, per the
[MCP stdio transport](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports).
It supports protocol versions 2024-11-05, 2025-03-26 and 2025-06-18. Send
`initialize`, then `notifications/initialized`, before `tools/list` or
`tools/call`. Frames are limited to 1 MiB. Calls execute sequentially; cancellation
notifications are ignored. Close stdin or terminate the child process to stop
the session. This version provides tools only, without resources, prompts,
subscriptions, an HTTP listener or GUI control.

WebCodex can run these CLI commands locally on behalf of ChatGPT. A ChatGPT web
connection cannot directly launch a local stdio process; WebCodex supplies the
local execution path. No additional network service is installed by this change.

## Build and verify

```sh
swift build -Xswiftc -warnings-as-errors
swift test -Xswiftc -warnings-as-errors
python3 scripts/test-automation.py "$(swift build --show-bin-path)/getGamen"
bash scripts/build-app.sh
```

The build script emits a signed universal app path. Replacing an installed build
may require renewing macOS Screen Recording permission. The automated transport
check uses generated images and does not capture the user's screen.

For an interactive launch regression, first close the GUI and stop any MCP host
that still runs an older build. Then run:

```sh
python3 scripts/test-launch-isolation.py /Applications/getGamen.app
```

This checks the helper's registered bundle identity, launches and reopens the GUI
with MCP active, and verifies that ending MCP leaves the GUI alive. It leaves
the GUI open. After upgrading from a build that ran MCP inside the GUI process,
restart the MCP host once to replace that already-running process.
