import SwiftUI
import PhotoCore

struct MetadataSidebar: View {
    let entry: CatalogEntry?
    let resource: PhotoResource?
    var resultingSize: CGSize? = nil
    @State private var metadata: PhotoMetadata?
    @State private var error: String?
    @State private var loading = false

    private var url: URL? { resource?.url ?? entry?.url }
    private var requestKey: String { "\(url?.path ?? "")|\(resource?.size ?? 0)|\(resource?.modified.timeIntervalSince1970 ?? 0)" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Сведения").font(.title2.bold())
                if let entry {
                    Label(entry.name, systemImage: entry.isFolder ? "folder" : "photo")
                        .font(.headline).textSelection(.enabled)
                    if let asset = entry.asset, asset.isPair {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("JPG + RAW").font(.subheadline.bold())
                            ForEach(asset.resources, id: \.url) { file in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(file.url.lastPathComponent).lineLimit(2)
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).foregroundStyle(.secondary)
                                }.font(.caption)
                            }
                            Text("Показаны данные: \(resource?.url.lastPathComponent ?? entry.name)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let resultingSize {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Размер после правок").font(.caption).foregroundStyle(.secondary)
                            Text("\(Int(resultingSize.width)) × \(Int(resultingSize.height))").font(.callout)
                        }
                    }
                    if loading { ProgressView("Чтение метаданных…") }
                    if let metadata {
                        ForEach(metadata.sections) { section in
                            VStack(alignment: .leading, spacing: 10) {
                                Divider()
                                Text(section.title).font(.headline)
                                ForEach(section.fields) { field in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(field.label).font(.caption).foregroundStyle(.secondary)
                                        Text(field.value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                        if let warning = metadata.warning { Text(warning).font(.callout).foregroundStyle(.secondary) }
                    }
                    if let error { Text(error).font(.callout).foregroundStyle(.secondary) }
                } else { Text("Выберите файл для просмотра метаданных.").foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
        .task(id: requestKey) {
            metadata = nil; error = nil; loading = false
            guard let url else { return }
            loading = true
            let worker = Task.detached(priority: .utility) { try PhotoMetadata.read(url: url) }
            do {
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled else { return }
                metadata = result; loading = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "Не удалось прочитать сведения: \(error.localizedDescription)"; loading = false
            }
        }
    }
}
