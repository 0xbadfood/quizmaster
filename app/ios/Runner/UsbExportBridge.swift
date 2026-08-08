import Flutter
import UIKit
import UniformTypeIdentifiers

final class UsbExportBridge: NSObject, UIDocumentPickerDelegate {
  static let shared = UsbExportBridge()

  private struct RootSession {
    let url: URL
    let isSecurityScoped: Bool
    let label: String
  }

  private struct NativeError: Error {
    let code: String
    let message: String
  }

  private let channelName = "storyvault/usb_export"
  private let selectedFolderLabel = "Selected USB Folder"
  private let rootUriPrefix = "iosdir://"
  private let ioQueue = DispatchQueue(label: "storyvault.usb_export.io")
  private var rootSessions: [String: RootSession] = [:]
  private var pendingPickerResult: FlutterResult?

  private override init() {
    super.init()
  }

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler(handleMethodCall)
  }

  private func handleMethodCall(
    call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "selectRoot":
      selectRoot(result: result)
    case "getDeviceInfo":
      runIoTask(result: result) { try self.getDeviceInfo(call: call) }
    case "releaseRoot":
      releaseRoot(call: call, result: result)
    case "listRoot":
      runIoTask(result: result) { try self.listRoot(call: call) }
    case "readTextFile":
      runIoTask(result: result) { try self.readTextFile(call: call) }
    case "writeTextFile":
      runIoTask(result: result) { try self.writeTextFile(call: call) }
    case "deleteRootFile":
      runIoTask(result: result) { try self.deleteRootFile(call: call) }
    case "copyFileToRoot":
      runIoTask(result: result) { try self.copyFileToRoot(call: call) }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func selectRoot(result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      guard self.pendingPickerResult == nil else {
        result(FlutterError(
          code: "usb_permission_pending",
          message: "Storage selection is already pending.",
          details: nil
        ))
        return
      }
      guard let presenter = self.topViewController else {
        result(FlutterError(
          code: "usb_open_failed",
          message: "Could not open the folder picker.",
          details: nil
        ))
        return
      }

      self.pendingPickerResult = result
      let picker: UIDocumentPickerViewController
      if #available(iOS 14.0, *) {
        picker = UIDocumentPickerViewController(
          forOpeningContentTypes: [.folder],
          asCopy: false
        )
      } else {
        picker = UIDocumentPickerViewController(
          documentTypes: ["public.folder"],
          in: .open
        )
      }
      picker.delegate = self
      picker.allowsMultipleSelection = false
      picker.modalPresentationStyle = .formSheet
      presenter.present(picker, animated: true)
    }
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    guard let pending = pendingPickerResult else { return }
    pendingPickerResult = nil
    guard let url = urls.first else {
      pending(nil)
      return
    }

    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
      pending(FlutterError(
        code: "unsupported_target",
        message: "Please choose the root folder of a Quizmaster USB device.",
        details: nil
      ))
      return
    }

    let scoped = url.startAccessingSecurityScopedResource()
    let token = rootUriPrefix + UUID().uuidString
    let label = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    rootSessions[token] = RootSession(
      url: url,
      isSecurityScoped: scoped,
      label: label.isEmpty ? selectedFolderLabel : label
    )
    pending(token)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pendingPickerResult?(nil)
    pendingPickerResult = nil
  }

  private var topViewController: UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
    var controller = window?.rootViewController
    while let presented = controller?.presentedViewController {
      controller = presented
    }
    return controller
  }

  private func runIoTask(
    result: @escaping FlutterResult,
    work: @escaping () throws -> Any?
  ) {
    ioQueue.async {
      do {
        let value = try work()
        DispatchQueue.main.async { result(value) }
      } catch let error as NativeError {
        DispatchQueue.main.async {
          result(FlutterError(code: error.code, message: error.message, details: nil))
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "usb_export_failed",
            message: error.localizedDescription,
            details: nil
          ))
        }
      }
    }
  }

  private func releaseRoot(call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      let rootUri = try requiredString(call: call, name: "rootUri")
      if let session = rootSessions.removeValue(forKey: rootUri), session.isSecurityScoped {
        session.url.stopAccessingSecurityScopedResource()
      }
      result(nil)
    } catch let error as NativeError {
      result(FlutterError(code: error.code, message: error.message, details: nil))
    } catch {
      result(FlutterError(code: "release_failed", message: error.localizedDescription, details: nil))
    }
  }

  private func getDeviceInfo(call: FlutterMethodCall) throws -> [String: Any] {
    let rootUri = try requiredString(call: call, name: "rootUri")
    let session = try rootSession(for: rootUri)
    let root = session.url
    let values = try? root.resourceValues(forKeys: [
      .volumeTotalCapacityKey,
      .volumeAvailableCapacityKey,
      .volumeAvailableCapacityForImportantUsageKey,
    ])
    return [
      "rootUri": rootUri,
      "label": "Writing to: \(session.label)",
      "volumeLabel": "",
      "manufacturer": "",
      "product": "",
      "capacity": Int64(values?.volumeTotalCapacity ?? 0),
      "freeSpace": values?.volumeAvailableCapacityForImportantUsage
        ?? Int64(values?.volumeAvailableCapacity ?? 0),
    ]
  }

  private func listRoot(call: FlutterMethodCall) throws -> [[String: Any]] {
    let root = try rootUrl(for: try requiredString(call: call, name: "rootUri"))
    let keys: Set<URLResourceKey> = [
      .fileSizeKey,
      .contentModificationDateKey,
      .isDirectoryKey,
    ]
    let urls = try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: Array(keys),
      options: []
    )
    return urls.map { file in
      let values = try? file.resourceValues(forKeys: keys)
      let modifiedMs = Int64((values?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)
      return [
        "name": file.lastPathComponent,
        "size": Int64(values?.fileSize ?? 0),
        "mimeType": values?.isDirectory == true ? "inode/directory" : "",
        "lastModified": modifiedMs,
      ]
    }
  }

  private func readTextFile(call: FlutterMethodCall) throws -> String? {
    let root = try rootUrl(for: try requiredString(call: call, name: "rootUri"))
    let fileName = try rootFileName(call: call)
    let url = root.appendingPathComponent(fileName, isDirectory: false)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }
    return try String(contentsOf: url, encoding: .utf8)
  }

  private func writeTextFile(call: FlutterMethodCall) throws -> Any? {
    let root = try rootUrl(for: try requiredString(call: call, name: "rootUri"))
    let fileName = try rootFileName(call: call)
    let text = try requiredString(call: call, name: "text")
    let url = root.appendingPathComponent(fileName, isDirectory: false)
    try text.data(using: .utf8)?.write(to: url, options: .atomic)
    return nil
  }

  private func deleteRootFile(call: FlutterMethodCall) throws -> Any? {
    let root = try rootUrl(for: try requiredString(call: call, name: "rootUri"))
    let fileName = try rootFileName(call: call)
    let url = root.appendingPathComponent(fileName, isDirectory: false)
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    return nil
  }

  private func copyFileToRoot(call: FlutterMethodCall) throws -> [String: Any] {
    let root = try rootUrl(for: try requiredString(call: call, name: "rootUri"))
    let sourcePath = try requiredString(call: call, name: "sourcePath")
    let fileName = try rootFileName(call: call)
    let source = URL(fileURLWithPath: sourcePath)
    guard FileManager.default.fileExists(atPath: source.path) else {
      throw NativeError(code: "source_missing", message: "Source file is missing.")
    }
    let target = root.appendingPathComponent(fileName, isDirectory: false)
    guard !FileManager.default.fileExists(atPath: target.path) else {
      throw NativeError(code: "target_exists", message: "Target file already exists.")
    }
    try FileManager.default.copyItem(at: source, to: target)
    let values = try? target.resourceValues(forKeys: [.fileSizeKey])
    return [
      "filename": fileName,
      "bytes": Int64(values?.fileSize ?? 0),
    ]
  }

  private func rootUrl(for rootUri: String) throws -> URL {
    return try rootSession(for: rootUri).url
  }

  private func rootSession(for rootUri: String) throws -> RootSession {
    guard rootUri.hasPrefix(rootUriPrefix), let session = rootSessions[rootUri] else {
      throw NativeError(
        code: "unsupported_target",
        message: "Please choose the root folder of a Quizmaster USB device."
      )
    }
    return session
  }

  private func requiredString(call: FlutterMethodCall, name: String) throws -> String {
    guard let args = call.arguments as? [String: Any],
          let value = args[name] as? String,
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw NativeError(code: "bad_args", message: "\(name) is required.")
    }
    return value
  }

  private func rootFileName(call: FlutterMethodCall) throws -> String {
    let fileName = try requiredString(call: call, name: "fileName")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !fileName.contains("/"), !fileName.contains("\\") else {
      throw NativeError(code: "bad_args", message: "Only root-level file names are supported.")
    }
    return fileName
  }
}
