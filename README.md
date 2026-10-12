# getGamen

[日本語](README.ja.md)

A macOS app that lets AI agents take screenshots and edit them for you. Capture, outline, crop, mask and mosaic are all available from a CLI and an MCP server. Every edit is saved as a new file, so a person can open each step and check it. It also works as an ordinary screenshot app you drive by hand.

getGamen supports macOS 14 or later on Apple silicon and Intel Macs. Real-device testing on macOS 14 (Sonoma) has not been done yet. The app's interface and Shortcuts actions are currently in Japanese only; CLI commands, MCP tool names and their schemas are in English, though some error messages may be in Japanese. It is built only with Apple frameworks: Swift, AppKit, SwiftUI, ScreenCaptureKit and Vision.

## Use it from an AI agent

Register getGamen as an MCP server in Claude Code, Codex or another agent, or let the agent call the `getGamen` command from the shell. For shell use, put a symbolic link to the app's executable on your PATH (see [CLI and MCP](docs/automation.md)). MCP configuration:

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

The agent can:

- List displays and windows, then capture a window or a region.
- Add outlines, masks and mosaics to an image, and crop it. Positions are in image pixels.
- Convert images to PNG, PNG8 or JPEG.

For example, ask "Capture the settings window, outline the Save button and mask the email address", and the agent finds the window, captures it and saves the edited image.

Every output is a new file; existing files are never overwritten. The original capture, the outlined version and the masked version stay as separate files, so you can compare them in order before pasting into a manual. Automation never sends images over the network and never copies them to the clipboard; the only network access is the license check with Lemon Squeezy, which sends the license key and this Mac's computer name.

A mosaic is a visual blur and does not reliably remove the underlying information. Use an opaque mask for anything that must not be readable in a published image. The unedited original also stays on disk, so publish or share only the edited files.

The command list, coordinate rules and Screen Recording permission details are in [CLI and MCP](docs/automation.md).

## Get it

- Download the signed and notarized DMG from [GitHub Releases](https://github.com/tmknzz/getGamen/releases).
- Manual use in the app is free. The CLI and MCP server work for a 7-day trial, then need a license from [Lemon Squeezy](https://tmknzz.lemonsqueezy.com/checkout/buy/2af738c0-6a22-457e-a868-06df153c2d27): $3 a month, or $30 once with a year of updates. Enter the key in Settings > ライセンス (License). Purchases fund development.
- Or build it from source. You need Xcode; see the [developer notes](docs/development.md) (Japanese). A build you make yourself is ad-hoc signed, so macOS may ask for Screen Recording permission again after each rebuild.

## Install

Open the DMG and drag getGamen to Applications. On the first capture, allow getGamen under System Settings > Privacy & Security > Screen Recording, then restart getGamen. When an agent captures, the MCP host or terminal app may need the same permission; see "Screen Recording permission" in [CLI and MCP](docs/automation.md).

Work data is kept temporarily in `~/Library/Application Support/getGamen`. Exported images go to the folder set in Settings (default `~/Pictures/getGamen`). To update, replace the app from a new DMG.

## Using the app

- Open the capture menu from the menu bar, the Dock or the default shortcut Control+Option+Command+Space. Capture a window, a region, the previous region, or a manual scrolling capture.
- In the editor, choose outline, mask, mosaic or crop and drag. Use the select tool to move items, resize from the bottom-right corner and Shift-click to select several. Edits are saved automatically once confirmed.
- Opening an image (File menu or dropping it on the Dock icon) copies the original into a new editor and never changes the input file.
- Batch conversion saves into a new folder per run. PNG8 is a true palette PNG; JPEG fills transparent areas with white.
- Scrolling capture advances downward by hand while keeping an overlap. It stops on an uncertain join and keeps the partial result; you can return to the last accepted position and resume.
- In Settings you can record, clear or reset shortcuts and turn launch at login on or off.

Originals and edit data are kept in `~/Library/Application Support/getGamen` and deleted when the editor closes. Data still saving, editors closed without saving, editors left open at quit and export records are cleaned up at the next launch. Partial scrolling captures are kept in the same place. Exported images stay in the output folder.

## Shortcuts app

These actions are available in the macOS Shortcuts app. Action names are in Japanese; English glosses are given in parentheses. The three capture actions and the capture menu can also be run from Spotlight.

- ウインドウを撮影 (Capture Window), 範囲を撮影 (Capture Region), 前と同じ範囲を撮影 (Capture Previous Region): capture with the usual picker and return the original PNG. The editor and automatic export run as usual. Pressing Esc cancels and stops the shortcut with an error.
- 撮影メニューを開く (Open Capture Menu): shows the capture menu.
- 画像を変換 (Convert Image): returns the image converted to PNG, PNG8 or JPEG (quality 0–1).
- 画像をクロップ (Crop), 枠で囲む (Outline), マスクをかける (Mask), モザイクをかける (Mosaic): the area is given in image pixels with a top-left origin. A Retina capture is twice the on-screen width and height in pixels. Outlines are orange (#FF9500) and can be a rectangle, rounded rectangle, circle or ellipse with a chosen line width. The result is a PNG; the input image is not changed.

Example: chain 範囲を撮影 → 枠で囲む → Save File, and set X, Y, width and height in 枠で囲む to save the capture with an orange outline.

When launched or run from Shortcuts, getGamen does not start the previous capture mode automatically. The first time an action passes an image, the Shortcuts app asks for permission to share it.

## License

MIT License. See [LICENSE](LICENSE).
