import Foundation
import CryptoKit

/// Manages a separately licensed Open Dictionary data package.
/// Code stays MIT; the downloaded/bundled data remains CC BY-SA 4.0.
struct OpenDictionaryRelease: Codable, Equatable {
    let tagName: String
    let htmlURL: URL
    let assets: [OpenDictionaryReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }

    var sqliteAsset: OpenDictionaryReleaseAsset? {
        assets.first { $0.name == "distribution.sqlite.gz" }
    }
}

struct OpenDictionaryReleaseAsset: Codable, Equatable {
    let name: String
    let size: Int64
    let digest: String?
    let downloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name, size, digest
        case downloadURL = "browser_download_url"
    }
}

struct OpenDictionaryInstallRecord: Codable {
    let tagName: String
    let installedAt: Date
}

enum OpenDictionaryLifecycleError: LocalizedError {
    case releaseMalformed
    case invalidDownload(String)
    case checksumMismatch
    case extractionFailed(String)
    case validationFailed

    var errorDescription: String? {
        switch self {
        case .releaseMalformed: return "Open Dictionary Release 元数据不完整。"
        case .invalidDownload(let detail): return "词库下载无效：\(detail)"
        case .checksumMismatch: return "下载文件的 SHA-256 校验失败，未替换现有词库。"
        case .extractionFailed(let detail): return "无法解压词库：\(detail)"
        case .validationFailed: return "新词库未通过 SQLite 查询验证，现有词库未被替换。"
        }
    }
}

actor OpenDictionaryLifecycle {
    static let releaseURL = URL(string: "https://api.github.com/repos/ahpxex/open-dictionary/releases/latest")!
    /// Bumped by the release builder when the separately bundled SQLite asset
    /// is refreshed. It lets first launch distinguish the bundled database from
    /// an unknown local file without consulting the network.
    static let bundledReleaseTag = "v2.0"

    private let fileManager = FileManager.default
    private let root: URL
    private let databaseURL: URL
    private let recordURL: URL

    init(applicationSupportRoot: URL) {
        root = applicationSupportRoot.appendingPathComponent("Dictionary", isDirectory: true)
        databaseURL = root.appendingPathComponent("distribution.sqlite")
        recordURL = root.appendingPathComponent("open-dictionary-install.json")
    }

    func managedDatabaseURL() -> URL? {
        fileManager.fileExists(atPath: databaseURL.path) ? databaseURL : nil
    }

    /// On first launch, copies the separately bundled database into writable
    /// Application Support. App updates do not overwrite the user's newer data.
    func installBundledDatabaseIfNeeded() throws -> URL? {
        guard !fileManager.fileExists(atPath: databaseURL.path) else { return databaseURL }
        guard let bundled = Bundle.main.url(forResource: "distribution", withExtension: "sqlite", subdirectory: "Dictionary") else { return nil }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.copyItem(at: bundled, to: databaseURL)
        try writeRecord(OpenDictionaryInstallRecord(tagName: Self.bundledReleaseTag, installedAt: Date()))
        return databaseURL
    }

    func installedRecord() -> OpenDictionaryInstallRecord? {
        guard let data = try? Data(contentsOf: recordURL) else { return nil }
        return try? JSONDecoder().decode(OpenDictionaryInstallRecord.self, from: data)
    }

    func checkLatestRelease() async throws -> OpenDictionaryRelease {
        var request = URLRequest(url: Self.releaseURL)
        request.timeoutInterval = 15
        request.setValue("WordWorkbench/0.3", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw OpenDictionaryLifecycleError.releaseMalformed }
        let release = try JSONDecoder().decode(OpenDictionaryRelease.self, from: data)
        guard release.sqliteAsset != nil else { throw OpenDictionaryLifecycleError.releaseMalformed }
        return release
    }

    func isUpdateAvailable(_ release: OpenDictionaryRelease) -> Bool {
        installedRecord()?.tagName != release.tagName
    }

    /// Downloads only after a deliberate UI confirmation. It verifies the
    /// publisher-provided asset digest, extracts to a staging file, performs a
    /// real lookup, then atomically replaces the managed database.
    func install(_ release: OpenDictionaryRelease) async throws -> URL {
        guard let asset = release.sqliteAsset else { throw OpenDictionaryLifecycleError.releaseMalformed }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let temporaryGzip = root.appendingPathComponent("distribution.sqlite.download.gz")
        let staging = root.appendingPathComponent("distribution.sqlite.next")
        try? fileManager.removeItem(at: temporaryGzip)
        try? fileManager.removeItem(at: staging)
        defer { try? fileManager.removeItem(at: temporaryGzip) }

        let (downloaded, response) = try await URLSession.shared.download(from: asset.downloadURL)
        if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
            throw OpenDictionaryLifecycleError.invalidDownload("服务器未返回成功状态")
        }
        try fileManager.moveItem(at: downloaded, to: temporaryGzip)
        guard let attributes = try? fileManager.attributesOfItem(atPath: temporaryGzip.path),
              let downloadedSize = attributes[.size] as? Int64,
              downloadedSize == asset.size else {
            throw OpenDictionaryLifecycleError.invalidDownload("文件大小与 Release 清单不一致")
        }
        if let digest = asset.digest {
            let expected = digest.replacingOccurrences(of: "sha256:", with: "").lowercased()
            guard try sha256(of: temporaryGzip) == expected else { throw OpenDictionaryLifecycleError.checksumMismatch }
        }
        try gzipExtract(source: temporaryGzip, destination: staging)
        guard (try? await OpenDictionarySource(databaseURL: staging).lookup(word: "organism")) != nil else {
            throw OpenDictionaryLifecycleError.validationFailed
        }
        if fileManager.fileExists(atPath: databaseURL.path) {
            _ = try fileManager.replaceItemAt(databaseURL, withItemAt: staging, backupItemName: "distribution.sqlite.previous")
        } else {
            try fileManager.moveItem(at: staging, to: databaseURL)
        }
        try writeRecord(OpenDictionaryInstallRecord(tagName: release.tagName, installedAt: Date()))
        return databaseURL
    }

    private func writeRecord(_ record: OpenDictionaryInstallRecord) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: recordURL, options: .atomic)
    }

    private func sha256(of url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func gzipExtract(source: URL, destination: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        task.arguments = ["-c", source.path]
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw OpenDictionaryLifecycleError.extractionFailed("无法创建临时 SQLite 文件")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        task.standardOutput = output
        task.standardError = Pipe()
        try task.run(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw OpenDictionaryLifecycleError.extractionFailed("gunzip 返回 \(task.terminationStatus)") }
    }
}
