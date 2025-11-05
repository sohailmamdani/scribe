"""
Scribe - Real-time speech-to-text Mac application
"""
import sys
from PyQt5.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QPushButton, QTextEdit, QLabel, QStatusBar, QProgressBar, QCheckBox
)
from PyQt5.QtCore import Qt, pyqtSignal, QObject, QTimer
from PyQt5.QtGui import QFont
from audio_capture import AudioCapture
from transcription_service import TranscriptionService
from post_processor import PostProcessor
from auto_paste import get_auto_paste
from global_hotkey import get_global_hotkey
import config
import time


class TranscriptionSignals(QObject):
    """Signals for thread-safe UI updates."""
    transcription_ready = pyqtSignal(str)
    status_update = pyqtSignal(str)
    loading_progress = pyqtSignal(bool)  # True = show progress, False = hide
    hotkey_triggered = pyqtSignal()  # Signal for global hotkey press


class Scribe(QMainWindow):
    """Main application window for Scribe."""

    def __init__(self):
        super().__init__()

        # Services
        self.audio_capture = None
        self.transcription_service = None
        self.post_processor = None

        # Signals for thread-safe UI updates
        self.signals = TranscriptionSignals()
        self.signals.transcription_ready.connect(self.on_transcription_ready)
        self.signals.status_update.connect(self.on_status_update)
        self.signals.loading_progress.connect(self.on_loading_progress)
        self.signals.hotkey_triggered.connect(self.toggle_recording)

        # UI state
        self.is_recording = False
        self.model_loaded = False
        self.auto_paste_enabled = config.AUTO_PASTE_ENABLED

        # Auto-paste utility
        self.auto_paste = get_auto_paste()

        # Global hotkey handler
        if config.GLOBAL_HOTKEY_ENABLED:
            self.global_hotkey = get_global_hotkey()
            self.global_hotkey.set_callback(self.on_hotkey_pressed)
            self.global_hotkey.start()
        else:
            self.global_hotkey = None

        self.init_ui()
        self.init_services()

    def init_ui(self):
        """Initialize the user interface."""
        self.setWindowTitle("Scribe")
        self.setGeometry(100, 100, 800, 600)

        # Central widget and layout
        central_widget = QWidget()
        self.setCentralWidget(central_widget)
        layout = QVBoxLayout(central_widget)
        layout.setSpacing(15)
        layout.setContentsMargins(20, 20, 20, 20)

        # Title
        title_label = QLabel("Scribe")
        title_font = QFont()
        title_font.setPointSize(24)
        title_font.setBold(True)
        title_label.setFont(title_font)
        title_label.setAlignment(Qt.AlignCenter)
        layout.addWidget(title_label)

        # Subtitle
        subtitle_label = QLabel("Real-time Speech-to-Text Transcription")
        subtitle_font = QFont()
        subtitle_font.setPointSize(12)
        subtitle_label.setFont(subtitle_font)
        subtitle_label.setAlignment(Qt.AlignCenter)
        subtitle_label.setStyleSheet("color: #666;")
        layout.addWidget(subtitle_label)

        # Hotkey info (if enabled)
        if config.GLOBAL_HOTKEY_ENABLED:
            hotkey_label = QLabel(f"Press {config.HOTKEY_DISPLAY_NAME} anywhere to start/stop recording")
            hotkey_font = QFont()
            hotkey_font.setPointSize(11)
            hotkey_label.setFont(hotkey_font)
            hotkey_label.setAlignment(Qt.AlignCenter)
            hotkey_label.setStyleSheet("color: #007AFF; padding: 5px;")
            layout.addWidget(hotkey_label)

        # Status indicator
        self.status_label = QLabel("Status: Initializing...")
        status_font = QFont()
        status_font.setPointSize(11)
        self.status_label.setFont(status_font)
        self.status_label.setStyleSheet("color: #333; padding: 10px;")
        layout.addWidget(self.status_label)

        # Progress bar (initially hidden)
        self.progress_bar = QProgressBar()
        self.progress_bar.setMinimum(0)
        self.progress_bar.setMaximum(0)  # Indeterminate progress
        self.progress_bar.setStyleSheet(
            "QProgressBar { "
            "border: 2px solid #ddd; "
            "border-radius: 5px; "
            "text-align: center; "
            "height: 25px; "
            "}"
            "QProgressBar::chunk { "
            "background-color: #007AFF; "
            "}"
        )
        self.progress_bar.setVisible(False)
        layout.addWidget(self.progress_bar)

        # Transcription display
        self.transcription_display = QTextEdit()
        self.transcription_display.setReadOnly(True)
        self.transcription_display.setPlaceholderText(
            "Transcribed text will appear here...\n\n"
            "Click 'Start Recording' to begin."
        )
        display_font = QFont("Menlo", 12)
        self.transcription_display.setFont(display_font)
        self.transcription_display.setStyleSheet(
            "QTextEdit { "
            "background-color: #f5f5f5; "
            "border: 2px solid #ddd; "
            "border-radius: 8px; "
            "padding: 15px; "
            "}"
        )
        layout.addWidget(self.transcription_display)

        # Control button
        self.record_button = QPushButton("Start Recording")
        self.record_button.setMinimumHeight(50)
        button_font = QFont()
        button_font.setPointSize(14)
        button_font.setBold(True)
        self.record_button.setFont(button_font)
        self.record_button.setStyleSheet(
            "QPushButton { "
            "background-color: #007AFF; "
            "color: white; "
            "border: none; "
            "border-radius: 8px; "
            "padding: 10px; "
            "}"
            "QPushButton:hover { "
            "background-color: #0051D5; "
            "}"
            "QPushButton:pressed { "
            "background-color: #003D99; "
            "}"
        )
        self.record_button.clicked.connect(self.toggle_recording)
        layout.addWidget(self.record_button)

        # Auto-paste checkbox
        self.auto_paste_checkbox = QCheckBox("Auto-paste to active window")
        self.auto_paste_checkbox.setChecked(self.auto_paste_enabled)
        checkbox_font = QFont()
        checkbox_font.setPointSize(12)
        self.auto_paste_checkbox.setFont(checkbox_font)
        self.auto_paste_checkbox.setStyleSheet(
            "QCheckBox { "
            "color: #333; "
            "padding: 8px; "
            "}"
            "QCheckBox::indicator { "
            "width: 20px; "
            "height: 20px; "
            "}"
            "QCheckBox::indicator:checked { "
            "background-color: #007AFF; "
            "border: 2px solid #007AFF; "
            "border-radius: 4px; "
            "}"
            "QCheckBox::indicator:unchecked { "
            "background-color: white; "
            "border: 2px solid #8E8E93; "
            "border-radius: 4px; "
            "}"
        )
        self.auto_paste_checkbox.stateChanged.connect(self.toggle_auto_paste)
        layout.addWidget(self.auto_paste_checkbox)

        # Clear button
        self.clear_button = QPushButton("Clear Text")
        self.clear_button.setMinimumHeight(40)
        clear_font = QFont()
        clear_font.setPointSize(12)
        self.clear_button.setFont(clear_font)
        self.clear_button.setStyleSheet(
            "QPushButton { "
            "background-color: #8E8E93; "
            "color: white; "
            "border: none; "
            "border-radius: 8px; "
            "padding: 8px; "
            "}"
            "QPushButton:hover { "
            "background-color: #636366; "
            "}"
        )
        self.clear_button.clicked.connect(self.clear_transcription)
        layout.addWidget(self.clear_button)

        # Status bar
        self.status_bar = QStatusBar()
        self.setStatusBar(self.status_bar)
        self.status_bar.showMessage("Ready")

    def init_services(self):
        """Initialize audio capture and transcription services."""
        # Show progress bar
        self.signals.loading_progress.emit(True)

        # Update status
        self.signals.status_update.emit("Initializing...")
        self.status_bar.showMessage("Starting up...")

        # Initialize transcription service with config settings
        self.transcription_service = TranscriptionService(
            model_size=config.WHISPER_MODEL_SIZE,
            on_transcription=self.on_transcription
        )

        # Initialize post-processor if enabled
        if config.POST_PROCESSING_ENABLED:
            self.post_processor = PostProcessor(
                model_name=config.POST_PROCESSING_MODEL,
                on_processed=None  # We'll handle this inline
            )

        # Load models in background
        import threading
        threading.Thread(
            target=self._load_models,
            daemon=True
        ).start()

    def _load_models(self):
        """Load the Whisper and post-processor models (called in background thread)."""
        # Load Whisper model
        success = self.transcription_service.load_model(
            on_progress=lambda msg: self.signals.status_update.emit(msg)
        )

        if not success:
            self.signals.status_update.emit("✗ Failed to load Whisper model - see console for details")
            self.signals.loading_progress.emit(False)
            return

        # Load post-processor if enabled
        if config.POST_PROCESSING_ENABLED and self.post_processor:
            post_success = self.post_processor.load_model(
                on_progress=lambda msg: self.signals.status_update.emit(msg)
            )

            if not post_success:
                self.signals.status_update.emit("⚠ Post-processor failed to load - continuing without it")
                self.post_processor = None

        self.model_loaded = True
        if config.POST_PROCESSING_ENABLED and self.post_processor:
            self.signals.status_update.emit("✓ Ready (Whisper + Mistral post-processing)")
        else:
            self.signals.status_update.emit("✓ Ready to transcribe")

        self.signals.loading_progress.emit(False)

        # Initialize audio capture after models are loaded
        self.audio_capture = AudioCapture(callback=self.on_audio_chunk)

    def toggle_recording(self):
        """Toggle recording state."""
        if not self.is_recording:
            self.start_recording()
        else:
            self.stop_recording()

    def start_recording(self):
        """Start recording audio."""
        if self.audio_capture is None:
            self.status_bar.showMessage("Error: Model not loaded yet")
            return

        if not self.transcription_service.is_loaded:
            self.status_bar.showMessage("Error: Model still loading")
            return

        success = self.audio_capture.start()
        if success:
            self.is_recording = True
            self.record_button.setText("Stop Recording")
            self.record_button.setStyleSheet(
                "QPushButton { "
                "background-color: #FF3B30; "
                "color: white; "
                "border: none; "
                "border-radius: 8px; "
                "padding: 10px; "
                "}"
                "QPushButton:hover { "
                "background-color: #CC2E25; "
                "}"
            )
            self.status_label.setText("Status: Listening...")
            self.status_bar.showMessage("Recording...")
        else:
            self.status_bar.showMessage("Error: Could not start recording")

    def stop_recording(self):
        """Stop recording audio."""
        if self.audio_capture:
            self.audio_capture.stop()

        self.is_recording = False
        self.record_button.setText("Start Recording")
        self.record_button.setStyleSheet(
            "QPushButton { "
            "background-color: #007AFF; "
            "color: white; "
            "border: none; "
            "border-radius: 8px; "
            "padding: 10px; "
            "}"
            "QPushButton:hover { "
            "background-color: #0051D5; "
            "}"
        )
        self.status_label.setText("Status: Ready")
        self.status_bar.showMessage("Ready")

    def on_audio_chunk(self, audio_data):
        """
        Called when audio chunk is ready for transcription.

        Args:
            audio_data: Numpy array of audio samples
        """
        self.signals.status_update.emit("Processing...")
        self.transcription_service.transcribe_async(audio_data)

    def on_transcription(self, text: str):
        """
        Called when transcription is complete (from background thread).

        Args:
            text: Transcribed text from Whisper
        """
        # Apply post-processing if enabled
        if config.POST_PROCESSING_ENABLED and self.post_processor and self.post_processor.is_loaded:
            # Update status to show post-processing
            self.signals.status_update.emit("Post-processing...")

            # Process the text to fix technical jargon
            corrected_text = self.post_processor.process(text)

            # Use corrected text if available, otherwise fall back to original
            final_text = corrected_text if corrected_text else text
        else:
            final_text = text

        # Emit signal for thread-safe UI update
        self.signals.transcription_ready.emit(final_text)

    def on_transcription_ready(self, text: str):
        """
        Handle transcription ready signal (called on main thread).

        Args:
            text: Transcribed text
        """
        if text:
            # Append transcription to display
            current_text = self.transcription_display.toPlainText()
            if current_text and not current_text.endswith('\n'):
                current_text += '\n'

            self.transcription_display.setPlainText(current_text + text + '\n')

            # Scroll to bottom
            scrollbar = self.transcription_display.verticalScrollBar()
            scrollbar.setValue(scrollbar.maximum())

            # Auto-paste if enabled
            if self.auto_paste_enabled:
                self._perform_auto_paste(text)

        # Update status
        if self.is_recording:
            self.status_label.setText("Status: Listening...")

    def on_status_update(self, message: str):
        """
        Handle status update signal (called on main thread).

        Args:
            message: Status message
        """
        self.status_bar.showMessage(message)

        # Also update the status label
        if not self.is_recording:
            if "✓" in message or "Ready" in message:
                self.status_label.setText(f"Status: {message}")
                self.status_label.setStyleSheet("color: #34C759; padding: 10px; font-weight: bold;")
            elif "✗" in message or "Error" in message or "Failed" in message:
                self.status_label.setText(f"Status: {message}")
                self.status_label.setStyleSheet("color: #FF3B30; padding: 10px; font-weight: bold;")
            else:
                self.status_label.setText(f"Status: {message}")
                self.status_label.setStyleSheet("color: #007AFF; padding: 10px;")

    def on_loading_progress(self, show: bool):
        """
        Handle loading progress signal (called on main thread).

        Args:
            show: True to show progress bar, False to hide
        """
        self.progress_bar.setVisible(show)

        # Disable record button while loading
        if not hasattr(self, 'record_button'):
            return

        if show:
            self.record_button.setEnabled(False)
            self.record_button.setText("Loading Model...")
        else:
            self.record_button.setEnabled(True)
            if self.model_loaded:
                self.record_button.setText("Start Recording")

    def on_hotkey_pressed(self):
        """
        Called when global hotkey is pressed (from background thread).
        Emits signal for thread-safe UI update.
        """
        self.signals.hotkey_triggered.emit()

    def toggle_auto_paste(self, state):
        """Toggle auto-paste functionality."""
        self.auto_paste_enabled = (state == Qt.Checked)
        status = "enabled" if self.auto_paste_enabled else "disabled"
        self.status_bar.showMessage(f"Auto-paste {status}", 2000)

    def _perform_auto_paste(self, text: str):
        """
        Perform auto-paste of transcribed text.

        Args:
            text: Text to paste
        """
        try:
            # Small delay to ensure transcription is complete
            time.sleep(config.AUTO_PASTE_DELAY)

            # Paste the text
            success = self.auto_paste.paste_text(
                text,
                restore_clipboard=config.RESTORE_CLIPBOARD_AFTER_PASTE
            )

            if success:
                # Visual feedback (brief status message)
                self.status_bar.showMessage("✓ Pasted", 1000)
            else:
                self.status_bar.showMessage("⚠ Paste failed", 2000)

        except Exception as e:
            print(f"Auto-paste error: {e}")
            self.status_bar.showMessage("⚠ Paste error", 2000)

    def clear_transcription(self):
        """Clear the transcription display."""
        self.transcription_display.clear()

    def closeEvent(self, event):
        """Handle window close event."""
        # Stop recording if active
        if self.is_recording:
            self.stop_recording()

        # Clean up resources
        if self.audio_capture:
            self.audio_capture.cleanup()

        if self.transcription_service:
            self.transcription_service.cleanup()

        if self.post_processor:
            self.post_processor.cleanup()

        # Stop global hotkey listener
        if self.global_hotkey:
            self.global_hotkey.stop()

        event.accept()


def main():
    """Main entry point for the application."""
    app = QApplication(sys.argv)

    # Set application-wide style
    app.setStyle("Fusion")

    window = Scribe()
    window.show()

    sys.exit(app.exec_())


if __name__ == "__main__":
    main()
