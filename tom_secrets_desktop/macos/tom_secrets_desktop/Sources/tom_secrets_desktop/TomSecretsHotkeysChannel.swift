// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

import Carbon
import Cocoa
import FlutterMacOS

/// `tom_secrets_desktop/hotkeys`: global hotkeys (quick access, auto-type;
/// part-app) through Carbon's `RegisterEventHotKey`, which needs no
/// permission. `register` takes `{id, keyCode, modifiers}` (the virtual key
/// and the names `control`, `alt`, `shift`, `meta`); a press is sent to Dart
/// as `pressed` with the id. Own code instead of a plugin (DP-32): the
/// hotkey plugins build through CocoaPods, which the app does not use.
enum TomSecretsHotkeys {
  static var channel: FlutterMethodChannel?
  static var refs: [String: EventHotKeyRef] = [:]
  static var names: [UInt32: String] = [:]
  static var next: UInt32 = 1
  static var installed = false
  // 'tsmk'
  static let signature: OSType = 0x7473_6D6B

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "tom_secrets_desktop/hotkeys", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "register":
        guard let id = args["id"] as? String,
          let keyCode = args["keyCode"] as? Int
        else {
          result(FlutterError(code: "bad_arguments", message: "id and keyCode", details: nil))
          return
        }
        let modifiers = args["modifiers"] as? [String] ?? []
        result(TomSecretsHotkeys.add(id: id, keyCode: keyCode, modifiers: modifiers))
      case "unregister":
        if let id = args["id"] as? String { TomSecretsHotkeys.remove(id: id) }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  static func install() {
    if installed { return }
    installed = true
    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, _ in
        var hotKey = EventHotKeyID()
        let status = GetEventParameter(
          event, EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID), nil,
          MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
        if status == noErr, let name = TomSecretsHotkeys.names[hotKey.id] {
          TomSecretsHotkeys.channel?.invokeMethod("pressed", arguments: name)
        }
        return noErr
      }, 1, &spec, nil, nil)
  }

  /// Registers the hotkey; answers an error text, or nil.
  static func add(id: String, keyCode: Int, modifiers: [String]) -> String? {
    install()
    remove(id: id)
    var mask: UInt32 = 0
    for m in modifiers {
      switch m {
      case "control": mask |= UInt32(controlKey)
      case "alt": mask |= UInt32(optionKey)
      case "shift": mask |= UInt32(shiftKey)
      case "meta": mask |= UInt32(cmdKey)
      default: break
      }
    }
    let number = next
    next += 1
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      UInt32(keyCode), mask, EventHotKeyID(signature: signature, id: number),
      GetApplicationEventTarget(), 0, &ref)
    guard status == noErr, let made = ref else {
      return "macOS refused the hotkey (\(status)): another program may use it"
    }
    refs[id] = made
    names[number] = id
    return nil
  }

  static func remove(id: String) {
    if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
    names = names.filter { $0.value != id }
  }
}
