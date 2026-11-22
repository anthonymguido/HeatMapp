import PhotosUI
import SwiftUI

struct SurveyListView: View {
    @EnvironmentObject private var store: SurveyStore
    @State private var showNew = false
    @State private var showSettings = false
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.surveys.isEmpty {
                    ContentUnavailableView {
                        Label("No surveys yet", systemImage: "wifi")
                    } description: {
                        Text("Add a floor plan, walk around, and tap where you're standing to measure the Wi-Fi.")
                    } actions: {
                        Button("New Survey") { showNew = true }.buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(store.surveys) { survey in
                            NavigationLink(value: survey.id) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(survey.name).font(.headline)
                                    Text("\(survey.points.count) points · \(survey.created.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { store.delete(at: $0) }
                    }
                }
            }
            .navigationTitle("Wi-Fi Heatmaps")
            .navigationDestination(for: UUID.self) { SurveyDetailView(surveyID: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showNew) {
                NewSurveySheet { id in
                    showNew = false
                    path.append(id)
                }
                .environmentObject(store)
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }
}

struct NewSurveySheet: View {
    @EnvironmentObject private var store: SurveyStore
    @Environment(\.dismiss) private var dismiss
    var onCreate: (UUID) -> Void

    @State private var name = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var showCamera = false
    @State private var loadFailed = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Home – 1st floor", text: $name)
                }
                Section {
                    if let image {
                        Image(uiImage: image)
                            .resizable().scaledToFit()
                            .frame(maxHeight: 180)
                            .frame(maxWidth: .infinity)
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(image == nil ? "Choose floor plan from Photos" : "Choose a different image", systemImage: "photo")
                    }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { showCamera = true } label: { Label("Take a photo of a floor plan", systemImage: "camera") }
                    }
                    if image != nil {
                        Button("Remove image", role: .destructive) { image = nil; photoItem = nil }
                    }
                } header: {
                    Text("Floor plan")
                } footer: {
                    Text("Optional. A screenshot, a photo of a sketch, or a scanned plan all work. Without one, you get a blank grid.")
                }
            }
            .navigationTitle("New Survey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let survey = store.create(name: name)
                        store.setFloorPlan(image ?? .blankGrid(), for: survey.id)
                        onCreate(survey.id)
                    }
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let ui = UIImage(data: data) {
                        image = ui
                    } else {
                        loadFailed = true
                    }
                }
            }
            .alert("Couldn't load that image", isPresented: $loadFailed) { Button("OK") {} }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image = $0 }.ignoresSafeArea()
            }
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ProbeSettings.latencyURLKey) private var latencyURL = ProbeSettings.defaultLatencyURL
    @AppStorage(ProbeSettings.downloadURLKey) private var downloadURL = ProbeSettings.defaultDownloadURL
    @AppStorage(ProbeSettings.pingCountKey) private var pingCount = 8

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Latency URL", text: $latencyURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Download URL", text: $downloadURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Stepper("Latency samples: \(pingCount)", value: $pingCount, in: 3...20)
                } header: {
                    Text("Test servers")
                } footer: {
                    Text("By default these test your internet connection. To measure only your Wi-Fi, point both URLs at a computer on your home network that serves a large file over HTTPS.")
                }
                Section {
                    Button("Reset to defaults") {
                        latencyURL = ProbeSettings.defaultLatencyURL
                        downloadURL = ProbeSettings.defaultDownloadURL
                        pingCount = 8
                    }
                }
                Section("About signal strength") {
                    Text("iOS doesn't let apps read Wi-Fi signal strength (RSSI). This app measures what you actually experience — throughput and latency — at each spot. If you have an RSSI reading from another source, you can type it in per point.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
