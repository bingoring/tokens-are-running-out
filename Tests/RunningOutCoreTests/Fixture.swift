import Foundation

/// Synthetic transcript lines shaped like real Claude Code records. No real data.
enum Fixture {
    static func call(
        id: String,
        at timestamp: String,
        session: String? = nil,
        model: String = "claude-opus-5-5",
        version: String = "2.1.325",
        input: Int = 2,
        output: Int = 10,
        read: Int = 0,
        write: Int = 0,
        ttl: String = "1h",
        iterations: [String]? = nil
    ) -> String {
        let sessionField = session.map { #","sessionId":"\#($0)""# } ?? ""
        let iterationsField = iterations.map { #","iterations":[\#($0.joined(separator: ","))]"# } ?? ""
        let write1h = ttl == "1h" ? write : 0
        let write5m = ttl == "5m" ? write : 0
        return """
            {"type":"assistant","timestamp":"\(timestamp)"\(sessionField),"version":"\(version)",\
            "message":{"id":"\(id)","model":"\(model)","usage":{"input_tokens":\(input),\
            "output_tokens":\(output),"cache_read_input_tokens":\(read),"cache_creation_input_tokens":\(write),\
            "cache_creation":{"ephemeral_1h_input_tokens":\(write1h),"ephemeral_5m_input_tokens":\(write5m)}\
            \(iterationsField)}}}

            """
    }

    /// One entry of `usage.iterations`: a sampling step of the call, or an advisor consult with its own model.
    static func iteration(
        type: String = "message", model: String? = nil, input: Int = 0, output: Int = 0, read: Int = 0,
        write: Int = 0, ttl: String = "1h"
    ) -> String {
        let modelField = model.map { #","model":"\#($0)""# } ?? ""
        let write1h = ttl == "1h" ? write : 0
        let write5m = ttl == "5m" ? write : 0
        return #"{"type":"\#(type)"\#(modelField),"input_tokens":\#(input),"output_tokens":\#(output),"#
            + #""cache_read_input_tokens":\#(read),"cache_creation_input_tokens":\#(write),"#
            + #""cache_creation":{"ephemeral_1h_input_tokens":\#(write1h),"ephemeral_5m_input_tokens":\#(write5m)}}"#
    }

    static func compact(at timestamp: String) -> String {
        #"{"type":"system","subtype":"compact_boundary","timestamp":"\#(timestamp)"}"# + "\n"
    }

    static func title(_ title: String, session: String) -> String {
        #"{"type":"custom-title","customTitle":"\#(title)","sessionId":"\#(session)"}"# + "\n"
    }

    static func user(_ text: String = "hi") -> String {
        #"{"type":"user","message":{"role":"user","content":"\#(text)"}}"# + "\n"
    }
}
