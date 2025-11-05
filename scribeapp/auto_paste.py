"""
Auto-paste utility for automatically pasting transcribed text
into the active application.
"""
import pyperclip
import time
from typing import Optional


class AutoPaste:
    """Handles automatic pasting of text to active application."""

    def __init__(self):
        """Initialize auto-paste functionality."""
        self._previous_clipboard = None
        self._setup_mac_paste()

    def _setup_mac_paste(self):
        """Setup macOS-specific paste functionality using Quartz."""
        try:
            from Quartz import (
                CGEventCreateKeyboardEvent,
                CGEventPost,
                CGEventSetFlags,
                kCGEventKeyDown,
                kCGEventKeyUp,
                kCGHIDEventTap,
                kCGEventFlagMaskCommand
            )
            self.CGEventCreateKeyboardEvent = CGEventCreateKeyboardEvent
            self.CGEventPost = CGEventPost
            self.CGEventSetFlags = CGEventSetFlags
            self.kCGEventKeyDown = kCGEventKeyDown
            self.kCGEventKeyUp = kCGEventKeyUp
            self.kCGHIDEventTap = kCGHIDEventTap
            self.kCGEventFlagMaskCommand = kCGEventFlagMaskCommand
            self._mac_available = True
        except ImportError:
            print("Warning: Quartz not available, auto-paste disabled")
            self._mac_available = False

    def paste_text(self, text: str, restore_clipboard: bool = True) -> bool:
        """
        Paste text into the currently active application.

        Args:
            text: Text to paste
            restore_clipboard: If True, restores previous clipboard contents after pasting

        Returns:
            True if successful, False otherwise
        """
        if not text or not text.strip():
            return False

        if not self._mac_available:
            print("Auto-paste not available on this system")
            return False

        try:
            # Save current clipboard content
            if restore_clipboard:
                try:
                    self._previous_clipboard = pyperclip.paste()
                except Exception:
                    self._previous_clipboard = None

            # Copy text to clipboard
            pyperclip.copy(text)

            # Small delay to ensure clipboard is updated
            time.sleep(0.05)

            # Simulate Cmd+V keypress on Mac
            self._simulate_paste_mac()

            # Restore previous clipboard after a delay
            if restore_clipboard and self._previous_clipboard is not None:
                # Wait a bit to ensure paste completes
                time.sleep(0.1)
                pyperclip.copy(self._previous_clipboard)

            return True

        except Exception as e:
            print(f"Error during auto-paste: {e}")
            return False

    def _simulate_paste_mac(self):
        """
        Simulate Cmd+V keypress on macOS using Quartz.
        """
        # Key code for 'V' is 9
        V_KEY = 9

        # Create key down event for 'V'
        key_down = self.CGEventCreateKeyboardEvent(None, V_KEY, True)
        # Set Cmd modifier
        self.CGEventSetFlags(key_down, self.kCGEventFlagMaskCommand)

        # Create key up event for 'V'
        key_up = self.CGEventCreateKeyboardEvent(None, V_KEY, False)

        # Post events
        self.CGEventPost(self.kCGHIDEventTap, key_down)
        time.sleep(0.01)  # Small delay between down and up
        self.CGEventPost(self.kCGHIDEventTap, key_up)

    def copy_to_clipboard_only(self, text: str) -> bool:
        """
        Copy text to clipboard without pasting.

        Args:
            text: Text to copy

        Returns:
            True if successful, False otherwise
        """
        try:
            pyperclip.copy(text)
            return True
        except Exception as e:
            print(f"Error copying to clipboard: {e}")
            return False


# Singleton instance
_auto_paste_instance = None


def get_auto_paste() -> AutoPaste:
    """Get the singleton AutoPaste instance."""
    global _auto_paste_instance
    if _auto_paste_instance is None:
        _auto_paste_instance = AutoPaste()
    return _auto_paste_instance
