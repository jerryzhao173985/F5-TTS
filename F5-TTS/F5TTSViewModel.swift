import Foundation
import F5TTS

import MLX
import Vocos

import AVFoundation
import Speech

import SwiftUI

import Speech
import UniformTypeIdentifiers

// First, modify AudioHistoryItem to store relative paths instead of URLs
struct AudioHistoryItem: Identifiable, Codable {
    var id: UUID = UUID()
    var title: String
    var audioFileName: String  // Store filename instead of URL
    
    enum CodingKeys: String, CodingKey {
        case id, title, audioFileName
    }
}
    
class F5TTSViewModel: ObservableObject {
    @Published var inputText: String = ""
    @Published var isGenerating: Bool = false
    @Published var generatedAudioURL: URL?
    @Published var audioHistory: [AudioHistoryItem] = []

    private var isTapInstalled = false
    private var outputPath: URL
    private var f5tts: F5TTS?
    private var audioEngine = AVAudioEngine()
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    private var isRecordingInProgress = false
    
    // New properties for reference audio
    var referenceAudioURL: URL?
    var referenceAudioText: String?

    
    private func getUniqueFileName() -> String {
        return "audio_\(UUID().uuidString).wav"
    }

    init() {
        // Create a unique file path for each audio generation
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        outputPath = documentsPath.appendingPathComponent("generatedAudio_\(UUID().uuidString).wav")
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        loadAudioHistory() // Load previous audios on startup
    }

    func requestPermissions() {
        // Request speech recognition authorization
        SFSpeechRecognizer.requestAuthorization { _ in }
        
        // Request microphone authorization
        AVAudioSession.sharedInstance().requestRecordPermission { _ in }
    }

    func initializeF5TTS() {
        Task {
            do {
                print("Loading F5-TTS model...")
                self.f5tts = try await F5TTS.fromPretrained(repoId: "lucasnewman/f5-tts-mlx") { progress in
                    print("Progress: \(progress.fractionCompleted * 100)%")
                }
            } catch {
                print("Failed to initialize F5TTS: \(error.localizedDescription)")
            }
        }
    }

    func handleFileImport(url: URL, completion: @escaping (Bool, String) -> Void) {
        // Request access to the iCloud file
        guard url.startAccessingSecurityScopedResource() else {
            completion(false, "Cannot access the file.")
            return
        }

        defer {
            url.stopAccessingSecurityScopedResource()  // Make sure to stop accessing the file after using it
        }

        do {
            let audioData = try Data(contentsOf: url)  // Read the file data
            DispatchQueue.main.async {
                self.inputText = String(data: audioData, encoding: .utf8) ?? ""
                completion(true, "File imported successfully")
            }
        } catch {
            completion(false, "Failed to read file: \(error.localizedDescription)")
        }
    }
    

    func startRecording(completion: @escaping (Bool, String) -> Void) {
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            completion(false, "Speech recognition is not available")
            return
        }

        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    self.setupAudioSession { success in
                        if success {
                            self.startSpeechRecognition(completion: completion)
                        } else {
                            completion(false, "Failed to setup audio session")
                        }
                    }
                case .denied:
                    completion(false, "Speech recognition permission denied")
                case .restricted:
                    completion(false, "Speech recognition is restricted")
                case .notDetermined:
                    completion(false, "Speech recognition not determined")
                @unknown default:
                    completion(false, "Unknown authorization status")
                }
            }
        }
    }

    private func setupAudioSession(completion: @escaping (Bool) -> Void) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            completion(true)
        } catch {
            print("Failed to setup audio session: \(error)")
            completion(false)
        }
    }
    
    private func startSpeechRecognition(completion: @escaping (Bool, String) -> Void) {
        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            completion(false, "Unable to create recognition request")
            return
        }

        recognitionRequest.shouldReportPartialResults = true

        do {
            let inputNode = audioEngine.inputNode
            
            // Remove existing tap if any
            if isTapInstalled {
                inputNode.removeTap(onBus: 0)
                isTapInstalled = false
            }

            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                self.recognitionRequest?.append(buffer)
            }
            isTapInstalled = true

            audioEngine.prepare()
            try audioEngine.start()

            recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                guard let self = self else { return }
                
                if let error = error {
                    print("Recognition error: \(error)")
                    completion(false, "Recognition error: \(error.localizedDescription)")
                    return
                }
                
                if let result = result {
                    DispatchQueue.main.async {
                        // Update inputText gradually with the latest transcription
                        let newTranscription = result.bestTranscription.formattedString
                        self.inputText = newTranscription // Always update with the latest transcription

                        // Optional: To avoid appending duplicates (if needed)
                        // if newTranscription != self.inputText {
                        //     self.inputText += newTranscription
                        // }
                    }
                }
            }

            completion(true, "Recording started successfully")
        } catch {
            completion(false, "Failed to start recording: \(error.localizedDescription)")
        }
    }
    
    func stopRecording() {
        audioEngine.stop()

        // Only clear the input text if you want to start a new recording session.
        // Do not clear text unless the user explicitly decides to clear or start over.
        
        // This flag indicates that we are finishing the current recording session.
        // You can decide to reset or save the text based on your desired flow.
        if !isRecordingInProgress {
            // If needed, you can reset the text here, but currently, we just preserve it.
            // inputText = "" // Uncomment to reset text when stopping after the second session
        }

        // Toggle the recording state
        isRecordingInProgress.toggle()
        
        // Reset audio session
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
    }
    
    // Modified generateSpeech to accept the reference audio parameters.
    func generateSpeech() {
        guard let f5tts = self.f5tts else {
            print("F5TTS not initialized.")
            return
        }
        
        isGenerating = true
        
        Task {
            do {
                let startTime = Date()
                let generatedAudio: MLXArray
                
                // If there is a reference audio file and a transcription available...
                if let refURL = referenceAudioURL,
                   let refText = referenceAudioText, !refText.isEmpty {
                   
                    // Re-open the security scope for the reference file.
                    if refURL.startAccessingSecurityScopedResource() {
                        defer { refURL.stopAccessingSecurityScopedResource() }
                        
                        generatedAudio = try await f5tts.generate(
                            text: self.inputText,
                            referenceAudioURL: refURL,
                            referenceAudioText: refText
                        )
                    } else {
                        // If reopening fails, log and fall back to generation without reference.
                        print("Unable to access reference audio file security scope.")
                        generatedAudio = try await f5tts.generate(text: self.inputText)
                    }
                } else {
                    // No reference file; generate using only input text.
                    generatedAudio = try await f5tts.generate(text: self.inputText)
                }
                
                let elapsedTime = Date().timeIntervalSince(startTime)
                print("Generated \(Double(generatedAudio.shape[0]) / Double(F5TTS.sampleRate)) seconds of audio in \(elapsedTime) seconds.")
                
                try AudioUtilities.saveAudioFile(url: outputPath, samples: generatedAudio)
                print("Saved audio to: \(outputPath)")
                
                DispatchQueue.main.async {
                    self.saveAudioToHistory()
                    self.generatedAudioURL = self.outputPath
                    self.isGenerating = false
                }
            } catch {
                print("Error generating speech: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isGenerating = false
                }
            }
        }
    }


    // Save audio to history
    func saveAudioToHistory() {
        let fileName = getUniqueFileName()
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destinationURL = documentsPath.appendingPathComponent(fileName)
        
        // Copy the generated audio to the permanent location
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: outputPath, to: destinationURL)
            
            let historyItem = AudioHistoryItem(title: inputText, audioFileName: fileName)
            audioHistory.append(historyItem)
            saveAudioHistory()
        } catch {
            print("Failed to save audio file: \(error)")
        }
    }
    
    // Update loading to verify files exist
    func loadAudioHistory() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let historyFileURL = documentsPath.appendingPathComponent("audioHistory.json")
        
        if let data = try? Data(contentsOf: historyFileURL),
           let savedHistory = try? JSONDecoder().decode([AudioHistoryItem].self, from: data) {
            
            // Filter out items whose audio files no longer exist
            audioHistory = savedHistory.filter { item in
                let audioURL = documentsPath.appendingPathComponent(item.audioFileName)
                return FileManager.default.fileExists(atPath: audioURL.path)
            }
        }
    }

    // Save audio history to disk
    func saveAudioHistory() {
        let fileManager = FileManager.default
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let historyFileURL = documentsPath.appendingPathComponent("audioHistory.json")

        if let data = try? JSONEncoder().encode(audioHistory) {
            try? data.write(to: historyFileURL)
        }
    }
    
    // Simplified transcription function (no iCloud or security-scoped code)
    func transcribeAudioFile(url: URL, completion: @escaping (String) -> Void) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            print("Speech recognizer not available")
            completion("")
            return
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        recognizer.recognitionTask(with: request) { result, error in
            if let error = error {
                print("Error transcribing audio: \(error.localizedDescription)")
                completion("")
                return
            }
            if let result = result {
                let transcription = result.bestTranscription.formattedString
                completion(transcription)
            } else {
                completion("")
            }
        }
    }
    
}
