"""
Global keyboard hotkey handler for Scribe.
Allows starting/stopping recording with a system-wide keyboard shortcut
without needing to focus the app window.
"""
from pynput import keyboard
from typing import Callable, Optional, Set
import threading


class GlobalHotkey:
    """Handles global keyboard shortcuts for the application."""

    def __init__(self, on_hotkey_pressed: Optional[Callable[[], None]] = None):
        """
        Initialize global hotkey handler.

        Args:
            on_hotkey_pressed: Callback function called when hotkey is pressed
        """
        self.on_hotkey_pressed = on_hotkey_pressed
        self.listener = None
        self.is_active = False

        # Track currently pressed keys
        self.current_keys: Set[keyboard.Key] = set()

        # Define the hotkey combination: Cmd+Option+Ctrl+V
        self.hotkey_combination = {
            keyboard.Key.cmd,      # Command
            keyboard.Key.alt,      # Option
            keyboard.Key.ctrl,     # Control
            keyboard.KeyCode.from_char('v')  # V key
        }

    def start(self) -> bool:
        """
        Start listening for global hotkeys.

        Returns:
            True if started successfully, False otherwise
        """
        if self.is_active:
            return True

        try:
            self.listener = keyboard.Listener(
                on_press=self._on_press,
                on_release=self._on_release
            )
            self.listener.start()
            self.is_active = True
            print("Global hotkey listener started (Cmd+Option+Ctrl+V)")
            return True

        except Exception as e:
            print(f"Error starting global hotkey listener: {e}")
            return False

    def stop(self):
        """Stop listening for global hotkeys."""
        if self.listener:
            self.listener.stop()
            self.is_active = False
            self.current_keys.clear()
            print("Global hotkey listener stopped")

    def _on_press(self, key):
        """
        Handle key press events.

        Args:
            key: The key that was pressed
        """
        try:
            # Add key to current keys set
            self.current_keys.add(key)

            # Check if hotkey combination is pressed
            if self._is_hotkey_pressed():
                # Call the callback in a separate thread to avoid blocking
                if self.on_hotkey_pressed:
                    threading.Thread(
                        target=self.on_hotkey_pressed,
                        daemon=True
                    ).start()

                # Clear current keys to prevent repeated triggers
                self.current_keys.clear()

        except Exception as e:
            print(f"Error in hotkey press handler: {e}")

    def _on_release(self, key):
        """
        Handle key release events.

        Args:
            key: The key that was released
        """
        try:
            # Remove key from current keys set
            self.current_keys.discard(key)

        except Exception as e:
            print(f"Error in hotkey release handler: {e}")

    def _is_hotkey_pressed(self) -> bool:
        """
        Check if the hotkey combination is currently pressed.

        Returns:
            True if all hotkey keys are pressed, False otherwise
        """
        # Check if all keys in the hotkey combination are pressed
        return self.hotkey_combination.issubset(self.current_keys)

    def set_callback(self, callback: Callable[[], None]):
        """
        Set or update the hotkey callback function.

        Args:
            callback: Function to call when hotkey is pressed
        """
        self.on_hotkey_pressed = callback


# Singleton instance
_global_hotkey_instance = None


def get_global_hotkey() -> GlobalHotkey:
    """Get the singleton GlobalHotkey instance."""
    global _global_hotkey_instance
    if _global_hotkey_instance is None:
        _global_hotkey_instance = GlobalHotkey()
    return _global_hotkey_instance
