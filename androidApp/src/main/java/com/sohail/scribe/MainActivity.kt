package com.sohail.scribe

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.provider.Settings
import android.text.format.DateUtils
import android.view.inputmethod.InputMethodManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import com.sohail.scribe.core.DictationHistoryItem
import com.sohail.scribe.core.DictationHistoryStore
import com.sohail.scribe.core.KeyboardPreferences
import com.sohail.scribe.core.ScribePreferences
import com.sohail.scribe.core.SymbolTapBehavior
import com.sohail.scribe.core.SymbolTapScope
import com.sohail.scribe.core.TranscriptPolisher
import com.sohail.scribe.speech.OnDeviceSpeechSession
import com.sohail.scribe.speech.OnDeviceModelStatus
import com.sohail.scribe.speech.SpeechSessionListener
import com.sohail.scribe.speech.SpeechSessionState

class MainActivity : ComponentActivity(), SpeechSessionListener {
    private lateinit var speechSession: OnDeviceSpeechSession
    private lateinit var historyStore: DictationHistoryStore
    private lateinit var preferenceStore: ScribePreferences

    private var speechState by mutableStateOf(SpeechSessionState.IDLE)
    private var speechMessage by mutableStateOf("Ready for private dictation")
    private var audioLevel by mutableFloatStateOf(0f)
    private var partialText by mutableStateOf("")
    private var history by mutableStateOf<List<DictationHistoryItem>>(emptyList())
    private var keyboardPreferences by mutableStateOf(KeyboardPreferences())
    private var hasMicrophonePermission by mutableStateOf(false)
    private var keyboardEnabled by mutableStateOf(false)
    private var keyboardSelected by mutableStateOf(false)
    private var onDeviceModelStatus by mutableStateOf(OnDeviceModelStatus.CHECKING)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        historyStore = DictationHistoryStore(this)
        preferenceStore = ScribePreferences(this)
        speechSession = OnDeviceSpeechSession(this, this) { onDeviceModelStatus = it }
        refreshState()

        setContent {
            ScribeTheme {
                ScribeApp(
                    speechState = speechState,
                    speechMessage = speechMessage,
                    audioLevel = audioLevel,
                    partialText = partialText,
                    history = history,
                    preferences = keyboardPreferences,
                    hasMicrophonePermission = hasMicrophonePermission,
                    keyboardEnabled = keyboardEnabled,
                    keyboardSelected = keyboardSelected,
                    onDeviceModelStatus = onDeviceModelStatus,
                    onToggleDictation = ::toggleDictation,
                    onCancelDictation = speechSession::cancel,
                    onRequestPermission = ::requestMicrophonePermission,
                    onOpenKeyboardSettings = ::openKeyboardSettings,
                    onShowKeyboardPicker = ::showKeyboardPicker,
                    onRequestModel = ::requestRecognitionModel,
                    onCopy = ::copyToClipboard,
                    onClearHistory = {
                        historyStore.clear()
                        history = emptyList()
                    },
                    onPreferencesChanged = { updated ->
                        keyboardPreferences = updated.normalized()
                        preferenceStore.keyboard = keyboardPreferences
                    },
                    onResetPreferences = {
                        preferenceStore.resetKeyboard()
                        keyboardPreferences = preferenceStore.keyboard
                    },
                )
            }
        }
    }

    override fun onResume() {
        super.onResume()
        if (::speechSession.isInitialized) refreshState()
    }

    override fun onDestroy() {
        if (::speechSession.isInitialized) speechSession.destroy()
        super.onDestroy()
    }

    override fun onStateChanged(state: SpeechSessionState, message: String) {
        speechState = state
        speechMessage = message
        if (state != SpeechSessionState.LISTENING) audioLevel = 0f
        if (state == SpeechSessionState.IDLE || state == SpeechSessionState.FAILED) partialText = ""
    }

    override fun onAudioLevel(level: Float) {
        audioLevel = level
    }

    override fun onPartialResult(text: String) {
        partialText = text
    }

    override fun onFinalResult(text: String) {
        val polished = TranscriptPolisher.polish(text)
        partialText = polished
        historyStore.add(polished)
        history = historyStore.load()
    }

    private fun refreshState() {
        hasMicrophonePermission = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.RECORD_AUDIO,
        ) == PackageManager.PERMISSION_GRANTED
        speechSession.checkModelSupport()
        val inputMethodManager = getSystemService(InputMethodManager::class.java)
        keyboardEnabled = inputMethodManager.enabledInputMethodList.any {
            it.packageName == packageName
        }
        keyboardSelected = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.DEFAULT_INPUT_METHOD,
        )?.startsWith(packageName) == true
        history = historyStore.load()
        keyboardPreferences = preferenceStore.keyboard
    }

    private fun toggleDictation() {
        when (speechState) {
            SpeechSessionState.LISTENING -> speechSession.stop()
            SpeechSessionState.PREPARING, SpeechSessionState.PROCESSING -> Unit
            else -> {
                if (hasMicrophonePermission) {
                    partialText = ""
                    speechSession.start()
                } else {
                    requestMicrophonePermission()
                }
            }
        }
    }

    private val microphonePermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        hasMicrophonePermission = granted
        if (granted) speechSession.start()
        else onStateChanged(SpeechSessionState.FAILED, "Microphone access is required for dictation.")
    }

    private fun requestMicrophonePermission() {
        microphonePermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
    }

    private fun openKeyboardSettings() {
        startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
    }

    private fun showKeyboardPicker() {
        getSystemService(InputMethodManager::class.java).showInputMethodPicker()
    }

    private fun requestRecognitionModel() {
        if (!speechSession.requestModelDownload()) {
            speechMessage = "This device does not expose an on-device model download API."
            speechState = SpeechSessionState.FAILED
        }
    }

    private fun copyToClipboard(text: String) {
        getSystemService(ClipboardManager::class.java)
            .setPrimaryClip(ClipData.newPlainText("Scribe dictation", text))
    }
}

private enum class AppPage { HOME, SETTINGS }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ScribeApp(
    speechState: SpeechSessionState,
    speechMessage: String,
    audioLevel: Float,
    partialText: String,
    history: List<DictationHistoryItem>,
    preferences: KeyboardPreferences,
    hasMicrophonePermission: Boolean,
    keyboardEnabled: Boolean,
    keyboardSelected: Boolean,
    onDeviceModelStatus: OnDeviceModelStatus,
    onToggleDictation: () -> Unit,
    onCancelDictation: () -> Unit,
    onRequestPermission: () -> Unit,
    onOpenKeyboardSettings: () -> Unit,
    onShowKeyboardPicker: () -> Unit,
    onRequestModel: () -> Unit,
    onCopy: (String) -> Unit,
    onClearHistory: () -> Unit,
    onPreferencesChanged: (KeyboardPreferences) -> Unit,
    onResetPreferences: () -> Unit,
) {
    var page by remember { mutableStateOf(AppPage.HOME) }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(if (page == AppPage.HOME) "Scribe" else "Keyboard settings") },
                navigationIcon = {
                    if (page == AppPage.SETTINGS) {
                        IconButton(onClick = { page = AppPage.HOME }) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                        }
                    }
                },
                actions = {
                    if (page == AppPage.HOME) {
                        IconButton(onClick = { page = AppPage.SETTINGS }) {
                            Icon(Icons.Default.Settings, contentDescription = "Keyboard settings")
                        }
                    }
                },
            )
        },
    ) { contentPadding ->
        when (page) {
            AppPage.HOME -> HomePage(
                modifier = Modifier.padding(contentPadding),
                speechState = speechState,
                speechMessage = speechMessage,
                audioLevel = audioLevel,
                partialText = partialText,
                history = history,
                hasMicrophonePermission = hasMicrophonePermission,
                keyboardEnabled = keyboardEnabled,
                keyboardSelected = keyboardSelected,
                onDeviceModelStatus = onDeviceModelStatus,
                onToggleDictation = onToggleDictation,
                onCancelDictation = onCancelDictation,
                onRequestPermission = onRequestPermission,
                onOpenKeyboardSettings = onOpenKeyboardSettings,
                onShowKeyboardPicker = onShowKeyboardPicker,
                onRequestModel = onRequestModel,
                onCopy = onCopy,
            )
            AppPage.SETTINGS -> KeyboardSettingsPage(
                modifier = Modifier.padding(contentPadding),
                preferences = preferences,
                onChanged = onPreferencesChanged,
                onReset = onResetPreferences,
                hasHistory = history.isNotEmpty(),
                onClearHistory = onClearHistory,
            )
        }
    }
}

@Composable
private fun HomePage(
    modifier: Modifier,
    speechState: SpeechSessionState,
    speechMessage: String,
    audioLevel: Float,
    partialText: String,
    history: List<DictationHistoryItem>,
    hasMicrophonePermission: Boolean,
    keyboardEnabled: Boolean,
    keyboardSelected: Boolean,
    onDeviceModelStatus: OnDeviceModelStatus,
    onToggleDictation: () -> Unit,
    onCancelDictation: () -> Unit,
    onRequestPermission: () -> Unit,
    onOpenKeyboardSettings: () -> Unit,
    onShowKeyboardPicker: () -> Unit,
    onRequestModel: () -> Unit,
    onCopy: (String) -> Unit,
) {
    LazyColumn(
        modifier = modifier.fillMaxSize().testTag("home-list"),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item {
            DictationHero(
                state = speechState,
                message = speechMessage,
                audioLevel = audioLevel,
                partialText = partialText,
                onToggle = onToggleDictation,
                onCancel = onCancelDictation,
            )
        }
        item {
            SetupCard(
                hasMicrophonePermission,
                keyboardEnabled,
                keyboardSelected,
                onRequestPermission,
                onOpenKeyboardSettings,
                onShowKeyboardPicker,
            )
        }
        item { KeyboardTestCard() }
        item {
            ModelCard(onDeviceModelStatus, onRequestModel)
        }
        if (history.isNotEmpty()) {
            item { Text("Recent dictations", style = MaterialTheme.typography.titleMedium) }
            items(history.take(10), key = { it.id }) { item ->
                HistoryCard(item, onCopy)
            }
        }
        item {
            InfoCard(
                icon = Icons.Default.Lock,
                title = "Private by design",
                detail = "Scribe explicitly uses Android's on-device recognizer. The app declares no internet permission and never stores microphone audio.",
            )
        }
    }
}

@Composable
private fun KeyboardTestCard() {
    var text by rememberSaveable { mutableStateOf("") }
    Card {
        Column(
            modifier = Modifier.fillMaxWidth().padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("Try the keyboard", style = MaterialTheme.typography.titleMedium)
            Text(
                "Tap below to verify typing and dictation before using Scribe in another app.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Test Scribe keyboard") },
                minLines = 2,
            )
        }
    }
}

@Composable
private fun DictationHero(
    state: SpeechSessionState,
    message: String,
    audioLevel: Float,
    partialText: String,
    onToggle: () -> Unit,
    onCancel: () -> Unit,
) {
    val busy = state == SpeechSessionState.PREPARING || state == SpeechSessionState.PROCESSING
    Card(shape = RoundedCornerShape(28.dp)) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            FilledIconButton(
                onClick = onToggle,
                enabled = !busy,
                modifier = Modifier.size(104.dp),
                shape = CircleShape,
            ) {
                when {
                    busy -> CircularProgressIndicator(color = MaterialTheme.colorScheme.onPrimary)
                    state == SpeechSessionState.LISTENING -> Text("■", fontSize = 34.sp)
                    else -> Text("●", fontSize = 42.sp)
                }
            }
            Text(
                when (state) {
                    SpeechSessionState.LISTENING -> "Recording is on"
                    SpeechSessionState.PROCESSING -> "Polishing your words"
                    SpeechSessionState.COMPLETED -> "Dictation complete"
                    SpeechSessionState.FAILED -> "Scribe needs attention"
                    SpeechSessionState.PREPARING -> "Preparing Scribe"
                    SpeechSessionState.IDLE -> "Tap to dictate"
                },
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
            )
            Text(message, textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (state == SpeechSessionState.LISTENING) {
                LinearProgressIndicator(progress = { audioLevel }, modifier = Modifier.fillMaxWidth())
                TextButton(onClick = onCancel) { Text("Cancel") }
            }
            if (partialText.isNotBlank()) {
                Text(partialText, style = MaterialTheme.typography.bodyLarge, textAlign = TextAlign.Center)
            }
        }
    }
}

@Composable
private fun SetupCard(
    hasPermission: Boolean,
    enabled: Boolean,
    selected: Boolean,
    onPermission: () -> Unit,
    onEnable: () -> Unit,
    onSelect: () -> Unit,
) {
    Card {
        Column(Modifier.fillMaxWidth().padding(18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("⌨", fontSize = 24.sp)
                Text("Use Scribe in every app", style = MaterialTheme.typography.titleMedium)
            }
            SetupRow("1", "Allow microphone", hasPermission, onPermission)
            SetupRow("2", "Enable Scribe keyboard", enabled, onEnable)
            SetupRow("3", "Select Scribe keyboard", selected, onSelect)
        }
    }
}

@Composable
private fun SetupRow(number: String, title: String, complete: Boolean, action: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        if (complete) {
            Icon(Icons.Default.CheckCircle, contentDescription = null, tint = Color(0xFF2E7D32))
        } else {
            Text("!", color = MaterialTheme.colorScheme.tertiary, fontWeight = FontWeight.Bold, fontSize = 22.sp)
        }
        Spacer(Modifier.size(10.dp))
        Text("$number. $title", modifier = Modifier.weight(1f))
        if (!complete) OutlinedButton(onClick = action) { Text("Set up") }
    }
}

@Composable
private fun ModelCard(status: OnDeviceModelStatus, onRequestModel: () -> Unit) {
    Card {
        Row(
            modifier = Modifier.fillMaxWidth().padding(18.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (status == OnDeviceModelStatus.READY) {
                Icon(Icons.Default.CheckCircle, contentDescription = null)
            } else {
                Text("!", color = MaterialTheme.colorScheme.tertiary, fontWeight = FontWeight.Bold, fontSize = 22.sp)
            }
            Column(Modifier.weight(1f)) {
                Text(
                    when (status) {
                        OnDeviceModelStatus.READY -> "On-device model ready"
                        OnDeviceModelStatus.CHECKING -> "Checking on-device model"
                        OnDeviceModelStatus.DOWNLOADING -> "Downloading on-device model"
                        OnDeviceModelStatus.PENDING -> "On-device model download scheduled"
                        OnDeviceModelStatus.DOWNLOADABLE -> "On-device model required"
                        OnDeviceModelStatus.UNAVAILABLE -> "On-device recognizer unavailable"
                        OnDeviceModelStatus.UNKNOWN -> "On-device model status unavailable"
                    },
                    style = MaterialTheme.typography.titleMedium,
                )
                Text(
                    when (status) {
                        OnDeviceModelStatus.READY -> "Speech stays on this device."
                        OnDeviceModelStatus.CHECKING -> "Asking Android which offline language model is installed."
                        OnDeviceModelStatus.DOWNLOADING -> "Android is preparing the private speech model."
                        OnDeviceModelStatus.PENDING -> "Android will finish the offline download when conditions allow."
                        OnDeviceModelStatus.DOWNLOADABLE -> "Install the offline speech model before dictating."
                        OnDeviceModelStatus.UNAVAILABLE -> "This device has no on-device recognition service."
                        OnDeviceModelStatus.UNKNOWN -> "Try a private dictation or request the offline model."
                    },
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (status == OnDeviceModelStatus.DOWNLOADABLE || status == OnDeviceModelStatus.UNKNOWN) {
                OutlinedButton(onClick = onRequestModel) { Text("Install") }
            }
        }
    }
}

@Composable
private fun HistoryCard(item: DictationHistoryItem, onCopy: (String) -> Unit) {
    Card(onClick = { onCopy(item.text) }) {
        Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(item.text)
                Text(
                    DateUtils.getRelativeTimeSpanString(item.createdAtMillis).toString(),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Text("⧉", fontSize = 22.sp)
        }
    }
}

@Composable
private fun InfoCard(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, detail: String) {
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer)) {
        Row(Modifier.fillMaxWidth().padding(18.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(icon, contentDescription = null)
            Column {
                Text(title, style = MaterialTheme.typography.titleMedium)
                Text(detail, color = MaterialTheme.colorScheme.onSecondaryContainer)
            }
        }
    }
}

@Composable
private fun KeyboardSettingsPage(
    modifier: Modifier,
    preferences: KeyboardPreferences,
    onChanged: (KeyboardPreferences) -> Unit,
    onReset: () -> Unit,
    hasHistory: Boolean,
    onClearHistory: () -> Unit,
) {
    LazyColumn(
        modifier = modifier.fillMaxSize().testTag("settings-list"),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item { SettingsHeader("Typing") }
        item { SettingsToggle("Autocorrection", preferences.autocorrectionEnabled) { onChanged(preferences.copy(autocorrectionEnabled = it)) } }
        item { SettingsToggle("Swipe typing", preferences.swipeTypingEnabled) { onChanged(preferences.copy(swipeTypingEnabled = it)) } }
        item { SettingsToggle("Double-space period", preferences.doubleSpacePeriodEnabled) { onChanged(preferences.copy(doubleSpacePeriodEnabled = it)) } }
        item { SettingsToggle("Key pop-up previews", preferences.keyPreviewsEnabled) { onChanged(preferences.copy(keyPreviewsEnabled = it)) } }
        item { SettingsHeader("Symbols") }
        item { SettingsToggle("Alternate symbols", preferences.alternateSymbolsEnabled) { onChanged(preferences.copy(alternateSymbolsEnabled = it)) } }
        item {
            Card {
                Column(Modifier.fillMaxWidth().padding(16.dp)) {
                    Text("Long-press delay: ${preferences.alternateHoldDelayMillis / 1000f} s")
                    Slider(
                        value = preferences.alternateHoldDelayMillis.toFloat(),
                        onValueChange = { onChanged(preferences.copy(alternateHoldDelayMillis = it.toInt())) },
                        valueRange = 250f..1_200f,
                        steps = 18,
                        enabled = preferences.alternateSymbolsEnabled,
                    )
                }
            }
        }
        item {
            SettingsChoice(
                title = "After tapping a symbol",
                first = "Stay on symbols",
                second = "Return to letters",
                firstSelected = preferences.symbolTapBehavior == SymbolTapBehavior.STAY,
                onFirst = { onChanged(preferences.copy(symbolTapBehavior = SymbolTapBehavior.STAY)) },
                onSecond = { onChanged(preferences.copy(symbolTapBehavior = SymbolTapBehavior.RETURN_TO_LETTERS)) },
            )
        }
        item {
            SettingsChoice(
                title = "Apply to",
                first = "Numbers & symbols",
                second = "Symbols only",
                firstSelected = preferences.symbolTapScope == SymbolTapScope.NUMBERS_AND_SYMBOLS,
                onFirst = { onChanged(preferences.copy(symbolTapScope = SymbolTapScope.NUMBERS_AND_SYMBOLS)) },
                onSecond = { onChanged(preferences.copy(symbolTapScope = SymbolTapScope.SYMBOLS_ONLY)) },
            )
        }
        item { SettingsHeader("Feedback") }
        item { SettingsToggle("Keyboard haptics", preferences.hapticsEnabled) { onChanged(preferences.copy(hapticsEnabled = it)) } }
        item {
            OutlinedButton(onClick = onReset, modifier = Modifier.fillMaxWidth()) { Text("Restore keyboard defaults") }
        }
        if (hasHistory) {
            item {
                TextButton(onClick = onClearHistory, modifier = Modifier.fillMaxWidth()) { Text("Clear dictation history") }
            }
        }
    }
}

@Composable private fun SettingsHeader(text: String) {
    Text(text, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary)
}

@Composable
private fun SettingsToggle(title: String, checked: Boolean, onChecked: (Boolean) -> Unit) {
    Card {
        Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(title, modifier = Modifier.weight(1f))
            Switch(checked = checked, onCheckedChange = onChecked)
        }
    }
}

@Composable
private fun SettingsChoice(
    title: String,
    first: String,
    second: String,
    firstSelected: Boolean,
    onFirst: () -> Unit,
    onSecond: () -> Unit,
) {
    Card {
        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(title, fontWeight = FontWeight.SemiBold)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (firstSelected) Button(onClick = onFirst) { Text(first) }
                else OutlinedButton(onClick = onFirst) { Text(first) }
                if (!firstSelected) Button(onClick = onSecond) { Text(second) }
                else OutlinedButton(onClick = onSecond) { Text(second) }
            }
        }
    }
}

@Composable
private fun ScribeTheme(content: @Composable () -> Unit) {
    MaterialTheme(content = content)
}
