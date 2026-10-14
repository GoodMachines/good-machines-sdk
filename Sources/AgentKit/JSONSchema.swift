import Foundation

/// A small JSON Schema builder for tool inputs. Covers what tool calling
/// needs; anything else can be passed as `.raw`.
public indirect enum JSONSchema: Sendable, Hashable {
    case string(description: String? = nil, enumValues: [String]? = nil)
    case integer(description: String? = nil, minimum: Int? = nil, maximum: Int? = nil)
    case number(description: String? = nil)
    case boolean(description: String? = nil)
    case array(of: JSONSchema, description: String? = nil)
    /// Properties not listed in `required` are optional.
    case object([String: JSONSchema], required: [String] = [], description: String? = nil)
    /// A field of a read's output with a sensitivity label (the "x-sensitivity" keyword).
    case sensitive(JSONSchema, Sensitivity)
    case raw(JSONValue)

    /// Whether a field of a read's output may reach the model.
    public enum Sensitivity: String, Sendable, Hashable {
        /// Sent as is (the default).
        case model
        /// The model sees only the last 4 characters.
        case masked
        /// Never reaches the model.
        case hidden
    }

    /// An object with no properties, for tools that take no input.
    public static let empty = JSONSchema.object([:])

    public var json: JSONValue {
        var o: [String: JSONValue] = [:]
        func describe(_ d: String?) { if let d { o["description"] = .string(d) } }
        switch self {
        case .string(let d, let values):
            o["type"] = "string"
            describe(d)
            if let values { o["enum"] = .array(values.map(JSONValue.string)) }
        case .integer(let d, let min, let max):
            o["type"] = "integer"
            describe(d)
            if let min { o["minimum"] = .number(Double(min)) }
            if let max { o["maximum"] = .number(Double(max)) }
        case .number(let d):
            o["type"] = "number"
            describe(d)
        case .boolean(let d):
            o["type"] = "boolean"
            describe(d)
        case .array(let items, let d):
            o["type"] = "array"
            o["items"] = items.json
            describe(d)
        case .object(let props, let required, let d):
            o["type"] = "object"
            o["properties"] = .object(props.mapValues(\.json))
            if !required.isEmpty { o["required"] = .array(required.sorted().map(JSONValue.string)) }
            o["additionalProperties"] = false
            describe(d)
        case .sensitive(let inner, let label):
            guard case .object(var labelled) = inner.json else { return inner.json }
            labelled["x-sensitivity"] = .string(label.rawValue)
            return .object(labelled)
        case .raw(let v):
            return v
        }
        return .object(o)
    }
}
