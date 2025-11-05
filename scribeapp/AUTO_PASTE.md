# Auto-Paste Feature

## What is Auto-Paste?

Auto-paste automatically inserts transcribed text into whatever application you're currently using. When transcription completes, the text is automatically pasted at your cursor position.

## How It Works

1. **You speak** into your microphone
2. **Scribe** processes the audio (~6-7 seconds)
3. **Text is transcribed** using Faster-Whisper
4. **Text automatically pastes** into your active window

No need to copy/paste manually!

## Usage

### Basic Usage

1. Start Scribe: `./run.sh`
2. Click in the text field where you want text to appear (email, document, chat, etc.)
3. Click "Start Recording" in Scribe
4. Speak
5. Text automatically appears where your cursor was!

### Toggle Auto-Paste

**In the UI**: Check/uncheck the "Auto-paste to active window" checkbox

**In config.py**:
```python
AUTO_PASTE_ENABLED = True  # or False
```

### Visual Feedback

When auto-paste occurs:
- Status bar shows "✓ Pasted" (green checkmark)
- If it fails: "⚠ Paste failed"

## Use Cases

### 1. Writing Emails
```
1. Open Gmail/Mail app
2. Click in email body
3. Start Scribe recording
4. Speak your email
5. Text appears automatically in email
```

### 2. Documentation
```
1. Open your text editor/Word/Google Docs
2. Position cursor where you want text
3. Record and speak
4. Documentation writes itself!
```

### 3. Messaging
```
1. Open Slack/Discord/Messages
2. Click in message field
3. Record voice message
4. Text pastes into chat
```

### 4. Code Comments
```
1. Open your IDE
2. Position cursor in comment block
3. Speak your comment
4. Auto-paste adds it to code
```

## Configuration

### Settings in `config.py`

```python
# Enable/disable auto-paste
AUTO_PASTE_ENABLED = True

# Restore your previous clipboard after pasting
# (so you don't lose what you had copied before)
RESTORE_CLIPBOARD_AFTER_PASTE = True

# Delay before pasting (seconds)
AUTO_PASTE_DELAY = 0.1
```

### Clipboard Behavior

**`RESTORE_CLIPBOARD_AFTER_PASTE = True` (default)**:
- Your previous clipboard is preserved
- Transcribed text pastes, then your old clipboard is restored
- You can still Cmd+V to paste what you had before

**`RESTORE_CLIPBOARD_AFTER_PASTE = False`**:
- Transcribed text stays in clipboard
- You can paste it again with Cmd+V
- Overwrites your previous clipboard

## How Auto-Paste Works Technically

1. **Copies text to clipboard** using `pyperclip`
2. **Saves your previous clipboard** (if restore enabled)
3. **Simulates Cmd+V keypress** using macOS Quartz framework
4. **Restores your clipboard** (if enabled)

This means it works with **any** app that accepts paste commands!

## Requirements

### macOS Accessibility Permissions

The first time you use auto-paste, macOS may prompt for permissions:

**"Scribe would like to control this computer using accessibility features"**

Click **"Open System Settings"** and enable:
- System Settings > Privacy & Security > Accessibility
- Enable Python or Terminal

This is required for simulating the Cmd+V keypress.

## Supported Applications

Auto-paste works with virtually any macOS app:

✅ Text Editors (VSCode, Sublime, Atom, vim, etc.)
✅ Email (Gmail, Outlook, Apple Mail)
✅ Messaging (Slack, Discord, Messages, WhatsApp)
✅ Documents (Google Docs, Microsoft Word, Pages)
✅ Browsers (Chrome, Safari, Firefox - web forms)
✅ IDEs (Xcode, IntelliJ, PyCharm)
✅ Note Apps (Notion, Evernote, Apple Notes)
✅ Terminal applications

## Troubleshooting

### Auto-paste doesn't work

**Check accessibility permissions**:
1. System Settings > Privacy & Security > Accessibility
2. Ensure Python/Terminal is enabled

**Try toggling the checkbox**:
- Uncheck "Auto-paste to active window"
- Check it again

**Check console for errors**:
Run manually to see errors:
```bash
source venv/bin/activate
python main.py
```

### Text pastes in wrong place

**Ensure cursor is active**:
- Click in the text field BEFORE recording
- Don't switch windows while recording
- Stay focused on target app

### Pasting too fast

Increase delay in `config.py`:
```python
AUTO_PASTE_DELAY = 0.3  # Slower (was 0.1)
```

### Clipboard not restoring

**Check setting**:
```python
RESTORE_CLIPBOARD_AFTER_PASTE = True
```

**Delay might be too short**:
Some apps need more time. Try increasing delay.

### Special characters not pasting

Some apps filter paste content. Try:
- Pasting into Notes app first (test)
- Check if app has paste restrictions
- Use "Clear Text" and manually copy instead

## Disable Auto-Paste

### Temporarily
Uncheck "Auto-paste to active window" in the UI

### Permanently
Edit `config.py`:
```python
AUTO_PASTE_ENABLED = False
```

Then text only appears in Scribe window (not auto-pasted).

## Privacy & Security

**Is auto-paste safe?**

Yes! Here's what happens:
- ✅ Only pastes YOUR transcribed text
- ✅ Only when YOU are recording
- ✅ All processing is local
- ✅ No keylogging or monitoring
- ✅ Only simulates Cmd+V when transcription completes

The app doesn't:
- ❌ Monitor your typing
- ❌ Capture other keystrokes
- ❌ Read from other apps
- ❌ Send data anywhere

## Tips for Best Results

1. **Click first, then record** - Ensure cursor is where you want text
2. **Don't switch apps** while recording
3. **Speak clearly** - Better transcription = better results
4. **Use short phrases** - Process and paste quickly
5. **Test in Notes first** - Verify auto-paste works

## Manual Paste Alternative

If you prefer manual control:
1. Disable auto-paste checkbox
2. Transcribed text appears in Scribe window
3. Select and copy text (Cmd+C)
4. Paste manually where needed (Cmd+V)

## Advanced: Keyboard Shortcut (Future)

Want a keyboard shortcut to toggle recording? That's a great idea for a future enhancement! For now:
- Keep Scribe window visible
- Click "Start Recording" when needed
- Or: Stay tuned for keyboard shortcut feature

## Summary

Auto-paste makes transcription seamless:
- ✅ No copy/paste needed
- ✅ Works with any app
- ✅ Preserves your clipboard
- ✅ Fast and automatic
- ✅ Toggle on/off anytime

Just speak, and the text appears where you need it! 🎙️✨
