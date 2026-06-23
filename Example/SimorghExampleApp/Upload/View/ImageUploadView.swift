//
//  ImageUploadView.swift
//  SimorghExampleApp
//
//  Created by Siamak on 12/18/24.
//

import PhotosUI
import SwiftUI

// Note: This example uses file.io for file uploading if needed.
struct ImageUploadView: View {
    @StateObject private var viewModel = UploadViewModel()
    @State private var selectedItem: PhotosPickerItem? = nil
    @State private var selectedImage: UIImage? = nil

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                if let image = selectedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 300)
                } else {
                    Text("Select an Image to Upload")
                        .foregroundColor(.gray)
                }

                PhotosPicker(
                    "Pick Image", selection: $selectedItem, matching: .images
                )
                .buttonStyle(.borderedProminent)

                if viewModel.showError {
                    Text("Error: \(viewModel.errorMessage)")
                        .foregroundColor(.red)
                }

                if let response = viewModel.uploadResponse {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Upload Successful!").font(.headline)
                        Text("File Name: \(response.name ?? "Unknown")")
                        Text("File Link: \(response.link ?? "N/A")")
                    }
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(10)
                }
            }
            .padding()
            .onChange(of: selectedItem) { oldValue, newValue in
                Task {
                    if let data = try? await newValue?.loadTransferable(
                        type: Data.self),
                        let image = UIImage(data: data)
                    {
                        selectedImage = image
                        await uploadImage(imageData: data)
                    }
                }
            }
            .navigationTitle("Image Uploader")
        }
    }

    @MainActor
    private func uploadImage(imageData: Data) async {
        do {
            try await viewModel.upload(file: imageData)
        } catch {
            viewModel.showError = true
            viewModel.errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    return ImageUploadView()
}
