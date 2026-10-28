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
    /// Filled by the camera; encoded into `photo` and released right away.
    @State private var capturedImage: UIImage?
    @State private var capturedMetadata: [String: Any]?
    /// The bytes Save will write (a library original, or the camera JPEG)
    /// plus a small preview — never a full-resolution bitmap.
    @State private var photo: ImageStore.PreparedPhoto?
    /// The newest camera/library request; an older, slower one that finishes
    /// later is ignored instead of replacing the newer photo.
    @State private var photoRequestID = UUID()
    @State private var itemDate: Date = .now

    @State private var showingCamera = false
    @State private var showingPhotoPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isLoadingPhoto = false

    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var showingCameraDenied = false
    @State private var isSaving = false

    private var hasPhoto: Bool {
        photo != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Photo") {
                    if let preview = photo?.preview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    Menu {
                        Button {
                            guard !isSaving else { return }
                            requestCameraAccess()
                        } label: {
                            Label("Take a Photo", systemImage: "camera")
                        }
                        Button {
                            guard !isSaving else { return }
                            showingPhotoPicker = true
                        } label: {
                            Label("Choose from Library", systemImage: "photo.on.rectangle")
                        }
                    } label: {
                        HStack {
                            Label(
                                hasPhoto ? "Change Photo" : "Add Photo",
                                systemImage: hasPhoto ? "arrow.triangle.2.circlepath" : "plus.circle"
                            )
                            Spacer()
                        }
                    }

                    if isLoadingPhoto {
                        ProgressView("Loading photo…")
                            .frame(maxWidth: .infinity)
                    }
                }

                if hasPhoto {
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
                    Button("Cancel") {
                        guard !isSaving else { return }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveItem() }
                        .disabled(!hasPhoto)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        // The camera UI is designed to own the whole screen; in a sheet it
        // becomes a small form sheet on the iPhone Duo's inner display.
        .fullScreenCover(isPresented: $showingCamera) {
            ImagePicker(image: $capturedImage, metadata: $capturedMetadata)
                .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showingPhotoPicker, selection: $selectedPhotoItem, matching: .images, photoLibrary: .shared())
        // Originals are stored byte-for-byte and travel in exported
        // collections, so leave the location out at the source.
        .photosPickerMetadataOptions(.removeLocation)
        .onChange(of: capturedImage) {
            // Camera just returned an image
            guard let capturedImage else { return }
            prepareCapture(capturedImage, metadata: capturedMetadata)
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

    private func prepareCapture(_ image: UIImage, metadata: [String: Any]?) {
        let requestID = UUID()
        photoRequestID = requestID
        isLoadingPhoto = true
        nonisolated(unsafe) let metadata = metadata
        // The encode below holds the only other reference; drop the ~46 MB frame once it finishes.
        capturedImage = nil
        capturedMetadata = nil
        Task {
            let prepared = await Task.detached(priority: .userInitiated) {
                ImageStore.preparePhoto(capturedImage: image, metadata: metadata)
            }.value
            // Ignore a stale encode if another photo was chosen meanwhile.
            guard photoRequestID == requestID else { return }
            isLoadingPhoto = false
            guard let prepared else {
                errorMessage = "Failed to process the photo."
                showingError = true
                return
            }
            photo = prepared
            itemDate = .now
        }
    }

    // MARK: - Library Import

    private func loadFromLibrary(item: PhotosPickerItem) {
        let requestID = UUID()
        photoRequestID = requestID
        isLoadingPhoto = true
        // Cleared so that picking the same photo again still reaches onChange.
        selectedPhotoItem = nil
        Task {
            // Decodes only a small preview; the original bytes are kept for saving.
            let data = try? await item.loadTransferable(type: Data.self)
            let prepared = await Task.detached(priority: .userInitiated) {
                data.flatMap { ImageStore.preparePhoto(from: $0) }
            }.value
            // Ignore a slow, stale pick if another photo was chosen meanwhile.
            guard photoRequestID == requestID else { return }
            guard let prepared else {
                errorMessage = "Failed to load the selected photo."
                showingError = true
                isLoadingPhoto = false
                return
            }

            // Prefer the date embedded in the photo; fall back to the library
            // asset's date, which is only readable with library access.
            var resolvedDate = prepared.captureDate
            if resolvedDate == nil, let assetID = item.itemIdentifier {
                resolvedDate = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject?.creationDate
            }

            photo = prepared
            itemDate = min(resolvedDate ?? .now, .now)
            isLoadingPhoto = false
        }
    }

    // MARK: - Save

    private func saveItem() {
        guard !isSaving, !isLoadingPhoto, let photo else { return }
        isSaving = true
        // The photo is pinned by the guards on the photo menu; notes and date
        // are read after the write completes, so what is persisted always
        // matches what is on screen at dismissal.
        Task {
            let filename = await Task.detached(priority: .userInitiated) {
                try? ImageStore.saveImageData(photo.data)
            }.value
            defer { isSaving = false }
            guard let filename else {
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
}
