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

            # Check for accessibility permissions
            self._permissions_granted = self._check_accessibility_permissions()
        except ImportError:
            print("Warning: Quartz not available, auto-paste disabled")
            self._mac_available = False
            self._permissions_granted = False

    def _check_accessibility_permissions(self) -> bool:
        """
        Check if the app has accessibility permissions on macOS.

        Returns:
            True if permissions are granted, False otherwise
        """
        try:
            # Try different import methods for AXIsProcessTrustedWithOptions
            try:
                # Method 1: Try Quartz.CoreGraphics
                from Quartz.CoreGraphics import AXIsProcessTrustedWithOptions, kAXTrustedCheckOptionPrompt
            except ImportError:
                try:
                    # Method 2: Try direct ApplicationServices import
                    from ApplicationServices import AXIsProcessTrustedWithOptions
                    kAXTrustedCheckOptionPrompt = "AXTrustedCheckOptionPrompt"
                except ImportError:
                    # Can't import - assume we need permissions
                    # This is safe because it will just show the dialog
                    return False

            # Check if process is trusted (has accessibility permissions)
            # Don't prompt here - we'll handle that in the UI
            trusted = AXIsProcessTrustedWithOptions({kAXTrustedCheckOptionPrompt: False})
            return trusted
        except (ImportError, AttributeError, Exception) as e:
            print(f"Could not check accessibility permissions: {e}")
            # If we can't check, assume we don't have them
            # The paste will still be attempted and may work anyway
            return False

    def request_accessibility_permissions(self) -> bool:
        """
        Request accessibility permissions from the user.
        This will show the system prompt.

        Returns:
            True if permissions are granted, False otherwise
        """
        try:
            # Try different import methods
            try:
                from Quartz.CoreGraphics import AXIsProcessTrustedWithOptions, kAXTrustedCheckOptionPrompt
            except ImportError:
                try:
                    from ApplicationServices import AXIsProcessTrustedWithOptions
                    kAXTrustedCheckOptionPrompt = "AXTrustedCheckOptionPrompt"
                except ImportError:
                    print("Could not import accessibility check functions")
                    return False

            # This will prompt the user to grant permissions
            trusted = AXIsProcessTrustedWithOptions({kAXTrustedCheckOptionPrompt: True})
            self._permissions_granted = trusted
            return trusted
        except (ImportError, Exception) as e:
            print(f"Could not request accessibility permissions: {e}")
            return False

    def has_permissions(self) -> bool:
        """Check if accessibility permissions are granted."""
        if not self._mac_available:
            return False
        # Re-check permissions in case they were granted since startup
        self._permissions_granted = self._check_accessibility_permissions()
        return self._permissions_granted

    def paste_text(self, text: str, restore_clipboard: bool = True) -> bool:
        """
        Paste text into the currently active application.

        Args:
            text: Text to paste
            restore_clipboard: If True, restores previous clipboard contents after pasting

        Returns:
            True if successful, False otherwise
            Returns "no_permissions" if accessibility permissions are not granted
        """
        if not text or not text.strip():
            return False

        if not self._mac_available:
            print("Auto-paste not available on this system")
            return False

        # Note: We try to paste even if we can't verify permissions
        # because the permission check import might fail even when permissions are granted
        # If the paste actually fails due to permissions, the error will be caught below

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
