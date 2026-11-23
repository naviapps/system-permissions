import Foundation

package struct PermissionDescriptor: Codable {
  package struct Custom: Codable {
    let capability: PermissionCapability
    let usageDescriptionKeys: [String]
  }
  let id: String
  let targetApplication: String?
  let custom: Custom?
}

extension PermissionType: Codable {
  package var descriptor: PermissionDescriptor {
    switch self {
    case .automation(let target):
      PermissionDescriptor(id: "automation", targetApplication: target, custom: nil)
    case .custom(let value):
      PermissionDescriptor(
        id: value.identifier, targetApplication: nil,
        custom: .init(
          capability: value.capability,
          usageDescriptionKeys: value.usageDescriptionKeys.map(\.rawValue)))
    default:
      PermissionDescriptor(id: id, targetApplication: nil, custom: nil)
    }
  }

  /// Projects a descriptor already validated and canonicalized by the Rust contract.
  package init(validatedDescriptor validated: PermissionDescriptor) throws {
    if let custom = validated.custom {
      self = .custom(
        CustomPermission(
          validatedIdentifier: validated.id, capability: custom.capability,
          usageDescriptionKeys: custom.usageDescriptionKeys.map(
            UsageDescriptionKey.init(validatedValue:))))
    } else if validated.id == "automation", let target = validated.targetApplication {
      self = .automation(targetApplication: target)
    } else if let type = Self.builtIn.first(where: { $0.id == validated.id }) {
      self = type
    } else {
      throw NativePermissions.Failure(
        code: "invalidDescriptor", message: "Unknown permission descriptor.")
    }
  }

  /// Decodes one portable permission descriptor from its original UTF-8 JSON bytes.
  /// Rust rejects malformed objects, including duplicate fields.
  public static func decodeJSON(_ data: Data) throws -> Self {
    try Self(validatedDescriptor: NativePermissions.decodeDescriptor(data))
  }

  public init(from decoder: Decoder) throws {
    // A generic Decoder supplies projected values. decodeJSON preserves the input bytes.
    let wire = try PermissionJSON(from: decoder)
    let validated: PermissionDescriptor = try NativePermissions.call([
      "op": "validateDescriptor", "permission": NativePermissions.object(wire),
    ])
    try self.init(validatedDescriptor: validated)
  }

  public func encode(to encoder: Encoder) throws { try descriptor.encode(to: encoder) }
}

/// Projects values from a generic Decoder into the shared JSON contract.
package enum PermissionJSON: Codable {
  case object([String: PermissionJSON])
  case array([PermissionJSON])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  package init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer()
    if value.decodeNil() {
      self = .null
    } else if let v = try? value.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? value.decode(String.self) {
      self = .string(v)
    } else if let v = try? value.decode([String: PermissionJSON].self) {
      self = .object(v)
    } else if let v = try? value.decode([PermissionJSON].self) {
      self = .array(v)
    } else {
      self = .number(try value.decode(Double.self))
    }
  }

  package func encode(to encoder: Encoder) throws {
    var value = encoder.singleValueContainer()
    switch self {
    case .object(let v): try value.encode(v)
    case .array(let v): try value.encode(v)
    case .string(let v): try value.encode(v)
    case .number(let v): try value.encode(v)
    case .bool(let v): try value.encode(v)
    case .null: try value.encodeNil()
    }
  }
}
