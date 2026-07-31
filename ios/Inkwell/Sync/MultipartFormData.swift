import Foundation

/// Just enough multipart/form-data encoding for the one request the app
/// sends: text fields plus one optional file part. Not a general-purpose
/// builder.
struct MultipartFormData {
    let boundary = UUID().uuidString
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, _ value: String) {
        body.append("--\(boundary)\r\n".utf8Data)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8Data)
        body.append(value.utf8Data)
        body.append("\r\n".utf8Data)
    }

    mutating func addFile(_ name: String, filename: String, contentType: String, data: Data) {
        body.append("--\(boundary)\r\n".utf8Data)
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8Data)
        body.append("Content-Type: \(contentType)\r\n\r\n".utf8Data)
        body.append(data)
        body.append("\r\n".utf8Data)
    }

    func finalized() -> Data {
        var closed = body
        closed.append("--\(boundary)--\r\n".utf8Data)
        return closed
    }
}

private extension String {
    var utf8Data: Data { Data(utf8) }
}
