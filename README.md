# volumeMixer

**volumeMixer** is a modern, lightweight macOS utility that brings per-application volume control to your menu bar. Unlike the default system volume, which controls all audio globally, volumeMixer allows you to adjust the gain of individual apps (like Chrome, Spotify, or Zoom) independently.

Built with **SwiftUI** and leveraging the latest **Core Audio Tap (CATap)** APIs introduced in macOS 14.2.

---

## ✨ Features

* **Individual Audio Control:** Adjust volume levels for specific apps without affecting system-wide audio.
* **Menu Bar Resident:** Lives entirely in your menu bar (`LSUIElement`) for a clutter-free workspace.
* **Automatic Detection:** Dynamically identifies apps currently producing audio using `kAudioHardwarePropertyProcessIsAudible`.
* **Native Look & Feel:** Displays high-resolution app icons and names for quick identification.
* **Modern Architecture:** Built using a "Graphify" approach to ensure a clear data flow between Core Audio and the UI.

---

## 🛠 Technical Stack

* **Language:** Swift 5.10+
* **Frameworks:** SwiftUI, CoreAudio, AudioToolbox, AVFoundation
* **Minimum OS:** macOS 14.2 (Sonoma) or later
* **API:** `CATap` (Core Audio Tap) for non-destructive audio interception.

---

## 🚀 Getting Started

### Prerequisites
* **Xcode 15.0+**
* **macOS 14.2+** (Required for `CATap` support)

### Installation & Building
1.  **Clone the repository:**
    ```bash
    git clone https://github.com/your-username/volumeMixer.git
    cd volumeMixer
    ```
2.  **Open the project:**
    Open `volumeMixer.xcodeproj` in Xcode.
3.  **Configure Build Settings:**
    * Ensure **Code Signing** is configured with your developer team.
    * Verify the `volumeMixer.entitlements` file is linked in **Build Settings** under **Code Signing Entitlements**.
    * Ensure the following frameworks are linked in **General > Frameworks, Libraries, and Embedded Content**:
        * `CoreAudio.framework`
        * `AudioToolbox.framework`
        * `AVFoundation.framework`
4.  **Run:**
    Press `Cmd + R` to build and run. The app will appear in your top menu bar.

---

## 🔒 Permissions
This app requires **Microphone/Audio Input** permissions. 
> **Note:** volumeMixer **does not** record your audio or save any data. This permission is a requirement of the macOS `CATap` API to allow one process to intercept the audio stream of another for the purpose of adjusting gain.

---

## 🏗 Architecture
The project follows a modular "Graphify" pattern:
* **Models:** `AudioProcess` – Data structure for PIDs and volume states.
* **Core:** `AudioManager` – The brain of the app. Handles polling for audible processes and managing the lifecycle of Audio Taps.
* **UI:** `MenuBarView` – A SwiftUI-based reactive interface that binds sliders directly to the audio engine.

---

## 🤝 Contributing
Contributions are welcome! If you have ideas for features (like audio presets or equalizer support), feel free to open an issue or submit a pull request.

---

### Created by Pavan
*Built with the help of AI coding agents and a passion for better macOS workflows.*
