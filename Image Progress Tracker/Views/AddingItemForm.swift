import SwiftUI
import SwiftData
import PhotosUI
import Photos
import AVFoundation

struct AddingItemForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    var group: TrackerGroup

    @State private var notes = ""
    @State private var capturedImage: UIImage?
    @State private var capturedMetadata: [String: Any]?
    @State private var itemDate: Date = .now
    @State private var hasDate = false

    @State private var showingCamera = false
    @State private var showingPhotoPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isLoadingPhoto = false

    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var showingCameraDenied = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Photo") {
                    if let image = capturedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    Menu {
                        Button {
                            requestCameraAccess()
                        } label: {
                            Label("Take a Photo", systemImage: "camera")
                        }
                        Button {
                            showingPhotoPicker = true
                        } label: {
                            Label("Choose from Library", systemImage: "photo.on.rectangle")
                        }
                    } label: {
                        HStack {
                            Label(
                                capturedImage == nil ? "Add Photo" : "Change Photo",
                                systemImage: capturedImage == nil ? "plus.circle" : "arrow.triangle.2.circlepath"
                            )
                            Spacer()
                        }
                    }

                    if isLoadingPhoto {
                        ProgressView("Loading photo…")
                            .frame(maxWidth: .infinity)
                    }
                }

                if capturedImage != nil {
                    Section("Date Taken") {
                        DatePicker(
                            "Date",
                            selection: $itemDate,
                            in: ...Date.now,
                            displayedComponents: .date
                        )
                    }
                }

                Section("Notes") {
                    TextField("Optional notes", text: $notes)
                }
            }
            .navigationTitle("Add Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveItem() }
                        .disabled(capturedImage == nil)
                }
            }
        }
        .sheet(isPresented: $showingCamera) {
            ImagePicker(image: $capturedImage, metadata: $capturedMetadata)
        }
        .photosPicker(isPresented: $showingPhotoPicker, selection: $selectedPhotoItem, matching: .images)
        .onChange(of: capturedImage) {
            // Camera just returned an image
            if capturedImage != nil && capturedMetadata != nil {
                itemDate = .now
                hasDate = true
            }
        }
        .onChange(of: selectedPhotoItem) {
            guard let selectedPhotoItem else { return }
            loadFromLibrary(item: selectedPhotoItem)
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
        .alert("Camera Access Required", isPresented: $showingCameraDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Please allow camera access in Settings to take photos.")
        }
    }

    // MARK: - Camera Permission

    private func requestCameraAccess() {
        // Fix #5: Check hardware availability first
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            errorMessage = "Camera is not available on this device."
            showingError = true
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showingCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                // Fix #4: Dispatch state updates back to main actor
                DispatchQueue.main.async {
                    if granted {
                        showingCamera = true
                    } else {
                        showingCameraDenied = true
                    }
                }
            }
        case .denied, .restricted:
            showingCameraDenied = true
        @unknown default:
            showingCameraDenied = true
        }
    }

    // MARK: - Library Import

    private func loadFromLibrary(item: PhotosPickerItem) {
        isLoadingPhoto = true
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = await Task.detached(priority: .userInitiated, operation: { UIImage(data: data) }).value else {
                await MainActor.run {
                    errorMessage = "Failed to load the selected photo."
                    showingError = true
                    isLoadingPhoto = false
                }
                return
            }

            // Try to get the creation date from the PHAsset via its identifier
            var resolvedDate: Date?
            if let assetID = item.itemIdentifier {
                let result = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
                resolvedDate = result.firstObject?.creationDate
            }

            await MainActor.run {
                capturedImage = image
                capturedMetadata = nil
                itemDate = resolvedDate ?? .now
                hasDate = resolvedDate != nil
                isLoadingPhoto = false
            }
        }
    }

    // MARK: - Save

    private func saveItem() {
        guard let image = capturedImage else { return }

        guard let filename = ImageStore.saveJPEG(image, metadata: capturedMetadata) else {
            errorMessage = "Failed to save the photo. Please try again."
            showingError = true
            return
        }

        let newItem = TrackerItem(imageFilename: filename, notes: notes, dateCreated: itemDate)
        newItem.group = group
        modelContext.insert(newItem)

        do {
            try modelContext.save()
        } catch {
            // Model save failed — clean up the orphaned image file
            ImageStore.deleteImage(filename: filename)
            errorMessage = "Failed to save. Please try again."
            showingError = true
            return
        }

        dismiss()
    }
}
