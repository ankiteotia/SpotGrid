//
//  ItemEditorSheet.swift
//  SpotGrid
//
//  Add an item to a spot, or edit one — name, notes, and photo. No AR here:
//  the camera option is safe because no ARSession is running (opening the
//  camera during the AR capture flow would interrupt the shared session).
//

import CoreTransferable
import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct ItemEditorSheet: View {

    enum Mode {
        case add(SpotModel)
        case edit(StoredAsset)
    }

    let mode: Mode

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var notes = ""
    @State private var photo: PhotoPair?
    @State private var photoChanged = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var isShowingCamera = false
    @State private var isLoadingPhoto = false
    @State private var didLoad = false

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Item name (e.g. Passport)", text: $name)
                    TextField("Notes (e.g. inside the blue folder)", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                photoSection

                if case .add(let spot) = mode {
                    Section("Goes In") {
                        Text(spot.locationText)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Item" : "Add Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(trimmedName.isEmpty || isLoadingPhoto)
                }
            }
            .onAppear(perform: loadIfNeeded)
            .onChange(of: pickerItem) { _, newItem in
                if let newItem { loadPickedPhoto(newItem) }
            }
            .fullScreenCover(isPresented: $isShowingCamera) {
                CameraPicker(
                    onCapture: { image in
                        photo = ImageSupport.photoPair(from: image)
                        photoChanged = true
                        isShowingCamera = false
                    },
                    onCancel: { isShowingCamera = false }
                )
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - Photo

    private var photoSection: some View {
        Section("Photo") {
            if let data = photo?.photo, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 220)
            }

            if isLoadingPhoto {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }

            if CameraPicker.isAvailable {
                Button {
                    isShowingCamera = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
            }

            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("Choose from Library", systemImage: "photo.on.rectangle")
            }

            if photo != nil {
                Button(role: .destructive) {
                    photo = nil
                    photoChanged = true
                } label: {
                    Label("Remove Photo", systemImage: "trash")
                }
            }
        }
    }

    private func loadPickedPhoto(_ selection: PhotosPickerItem) {
        isLoadingPhoto = true
        Task {
            if let data = try? await selection.loadTransferable(type: Data.self),
               let pair = ImageSupport.photoPair(from: data) {
                photo = pair
                photoChanged = true
            }
            isLoadingPhoto = false
            pickerItem = nil
        }
    }

    // MARK: - Load / save

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard case .edit(let item) = mode else { return }
        name = item.name
        notes = item.notes
        if let full = item.photoData, let thumbnail = item.thumbnailData {
            photo = PhotoPair(photo: full, thumbnail: thumbnail)
        }
    }

    private func save() {
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .add(let spot):
            Inventory.addItem(
                named: trimmedName,
                notes: trimmedNotes,
                photo: photo,
                to: spot,
                in: modelContext
            )
        case .edit(let item):
            // Renaming is always safe: the AR anchor belongs to the spot.
            item.name = trimmedName
            item.notes = trimmedNotes
            if photoChanged {
                Inventory.setPhoto(photo, for: item, in: modelContext)
            } else {
                try? modelContext.save()
            }
        }
        dismiss()
    }
}
