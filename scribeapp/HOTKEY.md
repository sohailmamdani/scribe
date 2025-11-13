# Global Hotkey Feature

## What is the Global Hotkey?

The global hotkey allows you to **start and stop recording from anywhere** without clicking into the Scribe window. This solves the key problem: you can keep your cursor in your email, document, or chat while dictating!

## The Hotkey

**`⌘⌥⌃V`** (Command + Option + Control + V)

Press this combination once to **start** recording, press again to **stop**.

## Why This Solves Your Problem

### The Problem
- To click "Start Recording" you had to focus Scribe window
- This meant losing focus on your target text field
- Auto-paste had nowhere to paste!

### The Solution
1. Click in your email/document/chat (where you want text)
2. Press **`⌘⌥⌃V`** (focus stays in your app!)
3. Speak
4. Press **`⌘⌥⌃V`** again to stop
5. Text auto-pastes exactly where your cursor was!

## Complete Workflow Example

### Writing an Email
```
1. Open Gmail
2. Click in email body (cursor ready)
3. Press ⌘⌥⌃V (recording starts, focus stays in Gmail!)
4. Speak: "Hi team, I wanted to update you on..."
5. Press ⌘⌥⌃V (recording stops)
6. Text appears in your email!
7. Keep typing or press ⌘⌥⌃V again for more
```

### Taking Notes
```
1. Open Notion/Notes/Google Docs
2. Click where you want text
3. Press ⌘⌥⌃V
4. Speak your thoughts
5. Press ⌘⌥⌃V
6. Continue typing or dictate more
```

### Coding Comments
```
1. Position cursor in code comment
2. Press ⌘⌥⌃V
3. Explain the code
4. Press ⌘⌥⌃V
5. Comment appears, keep coding
```

## Requirements

### macOS Accessibility Permissions

The first time you use the hotkey, macOS will prompt:

**"Python would like to receive keystrokes from any application"**

Click **"Open System Settings"** and enable:
- System Settings > Privacy & Security > Accessibility
- Enable Python or Terminal

This is required for:
1. Listening to your global hotkey press
2. Simulating Cmd+V for auto-paste

## How It Works

1. **Scribe runs in background** - Window can be minimized or hidden
2. **Hotkey listener is always active** - Waits for ⌘⌥⌃V
3. **You press the hotkey** - From any app
4. **Recording starts** - Scribe captures audio
5. **You press hotkey again** - Recording stops
6. **Text auto-pastes** - Into your active window

All while **never losing focus** on your target app!

## Visual Feedback

When using the hotkey:
- **Scribe window** shows recording status (if visible)
- **Status bar** updates (if visible)
- **Button** changes to "Stop Recording" (if visible)
- **But you don't need to see any of this!**

The window can be completely hidden and it still works.

## Best Practices

### 1. Keep Scribe Running in Background
- Launch Scribe: `./run.sh`
- Minimize or hide the window
- Use ⌘⌥⌃V whenever you need to dictate

### 2. Position Cursor First
- Always click where you want text BEFORE pressing hotkey
- The hotkey doesn't move your cursor
- Auto-paste goes where cursor is

### 3. Short Recordings Work Best
- Press hotkey, speak a sentence or paragraph
- Press hotkey to stop
- Repeat for more text
- This gives faster feedback than long recordings

### 4. Visual Confirmation (Optional)
- Keep Scribe window visible in corner if you want
- See status updates
- Not required for functionality

## Configuration

### Change the Hotkey

To use a different key combination, edit `global_hotkey.py`:

```python
# Current: Cmd+Option+Ctrl+V
self.hotkey_combination = {
    keyboard.Key.cmd,      # Command
    keyboard.Key.alt,      # Option
    keyboard.Key.ctrl,     # Control
    keyboard.KeyCode.from_char('v')  # V key
}

# Example: Change to Cmd+Shift+D
self.hotkey_combination = {
    keyboard.Key.cmd,
    keyboard.Key.shift,
    keyboard.KeyCode.from_char('d')
}
```

Don't forget to update `config.py`:
```python
HOTKEY_DISPLAY_NAME = "⌘⇧D"  # New display name
```

### Disable Global Hotkey

If you prefer clicking the button, edit `config.py`:
```python
GLOBAL_HOTKEY_ENABLED = False
```

## Troubleshooting

### Hotkey doesn't work

**Check accessibility permissions**:
1. System Settings > Privacy & Security > Accessibility
2. Ensure Python/Terminal is enabled
3. Restart Scribe after enabling

**Check if Scribe is running**:
```bash
ps aux | grep "python main.py"
```

Should show a running process.

**Try clicking the button first**:
- If button works but hotkey doesn't, it's a permissions issue
- Grant accessibility permissions

### Hotkey triggers but doesn't record

**Check model is loaded**:
- Window shows "Status: Ready to transcribe"
- If still loading, wait for model download

**Check console for errors**:
```bash
source venv/bin/activate
python main.py
```

Watch for error messages when pressing hotkey.

### Hotkey conflicts with other app

**Change the hotkey** (see Configuration above)

Common conflicts:
- Some IDEs use Ctrl+V combinations
- Some clipboard managers use similar combinations
- Choose an unused combination

### Auto-paste doesn't work with hotkey

**Ensure auto-paste is enabled**:
- Check checkbox in Scribe window
- Or set in `config.py`: `AUTO_PASTE_ENABLED = True`

**Grant paste permissions**:
- Same accessibility permissions needed
- System Settings > Privacy & Security > Accessibility

### Recording doesn't stop

**Press hotkey again** - Must press same hotkey to toggle

**If stuck, click Stop Recording button**

**Or restart app**: Cmd+Q and `./run.sh`

## Advanced Usage

### Minimize to Background
```bash
# Launch Scribe
./run.sh

# Minimize window (Cmd+M)
# Use ⌘⌥⌃V anytime
```

### Multiple Dictation Sessions
```
Press ⌘⌥⌃V → Speak → Press ⌘⌥⌃V → (text pastes)
Press ⌘⌥⌃V → Speak → Press ⌘⌥⌃V → (text pastes)
Press ⌘⌥⌃V → Speak → Press ⌘⌥⌃V → (text pastes)
```

Each session is independent, text accumulates in your document.

### Switch Between Apps
```
1. Dictate into email (⌘⌥⌃V)
2. Switch to Notes
3. Dictate into notes (⌘⌥⌃V)
4. Switch to Slack
5. Dictate into Slack (⌘⌥⌃V)
```

Works seamlessly across all apps!

## Comparison: Button vs Hotkey

| Feature | Button Click | Global Hotkey |
|---------|-------------|---------------|
| Focus required | Yes - must click Scribe | No - stay in your app |
| Cursor position | Lost when clicking | Preserved |
| Auto-paste works | No (wrong focus) | Yes (correct focus) |
| Convenience | Click, switch, wait | Press, speak, done |
| Workflow speed | Slow | Fast |
| Hands-free | No | Yes (after positioning cursor) |

**Winner**: Global Hotkey 🎉

## Tips for Maximum Productivity

1. **Launch Scribe at startup** - Always ready
2. **Minimize to background** - Out of the way
3. **Use hotkey exclusively** - Faster than clicking
4. **Keep cursor ready** - Position where you want text
5. **Short bursts** - Dictate paragraph by paragraph
6. **Edit as you go** - Mix typing and dictation

## Summary

The global hotkey **`⌘⌥⌃V`** transforms Scribe from a standalone app into a **system-wide dictation tool**:

✅ Start/stop recording from anywhere
✅ Never lose focus on your work
✅ Auto-paste works perfectly
✅ Fast, seamless workflow
✅ No window switching needed

Just press the hotkey and speak - it's that simple! 🎙️✨
